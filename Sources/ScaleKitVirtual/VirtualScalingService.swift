import CoreGraphics
import Foundation
import ScaleKitCore

/// The confirm-or-revert flow for virtual-display scaling.
///
/// It mirrors `RecoveryService`: a journal is written first, ScaleKitGuard
/// watches it, the change is applied for this process only, and a countdown
/// turns it off unless the user keeps it. "Keep" saves a preference so the
/// scaling is re-applied the next time ScaleKit starts; the scaling itself
/// always lasts only while ScaleKit runs.
@MainActor
public final class VirtualScalingService {
    public enum State: Sendable, Equatable {
        case off
        case applying
        case awaitingConfirmation(VirtualScalingSession, deadline: Date)
        case active(VirtualScalingSession)

        public var session: VirtualScalingSession? {
            switch self {
            case .awaitingConfirmation(let session, _), .active(let session): session
            case .off, .applying: nil
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        case kept(VirtualScalingSession)
        case turnedOff(VirtualScalingSession, reason: String, automatic: Bool)
        case failed(String)
        case restoredAtLaunch(VirtualScalingSession)
    }

    public private(set) var state: State = .off {
        didSet { onStateChange?(state) }
    }

    public var onStateChange: (@MainActor (State) -> Void)?
    public var onOutcome: (@MainActor (Outcome) -> Void)?
    public var confirmationTimeout: TimeInterval = 15
    public var guardGrace: TimeInterval = 8

    public let scaler: VirtualDisplayScaler
    private let journalStore: JSONFileStore<TrialJournal>
    private let preferenceStore: JSONFileStore<VirtualScalingPreference>
    private let history: HistoryStore
    private let guardLauncher: GuardLauncher?
    private let guardLogURL: URL
    private let identityStore: JSONFileStore<VirtualIdentityState>
    private var timerTask: Task<Void, Never>?

    /// Marks a journal written while re-applying saved scaling, so a crash
    /// during that step is recognised at the next launch.
    static let reapplyNote = "Re-applying saved scaling"

    /// `journalURL` lets the CLI keep its own journal so it never overwrites the app's.
    public init(
        hardware: DisplayHardware, paths: AppPaths, history: HistoryStore,
        guardLauncher: GuardLauncher? = ProcessGuardLauncher.locate(), journalURL: URL? = nil
    ) {
        scaler = VirtualDisplayScaler(hardware: hardware)
        journalStore = JSONFileStore(url: journalURL ?? paths.virtualTrialJournalFile)
        preferenceStore = JSONFileStore(url: paths.virtualScalingFile)
        identityStore = JSONFileStore(url: paths.root.appendingPathComponent("virtual-identity.json"))
        self.history = history
        self.guardLauncher = guardLauncher
        guardLogURL = paths.guardLogFile
        scaler.identityGeneration = (try? identityStore.load())?.generation ?? 1
        scaler.onUnexpectedTermination = { [weak self] session in
            self?.virtualDisplayVanished(session)
        }
    }

    /// Gives future virtual displays a new identity, discarding whatever
    /// WindowServer saved for the old one.
    private func bumpIdentity() {
        scaler.identityGeneration &+= 1
        try? identityStore.save(VirtualIdentityState(generation: scaler.identityGeneration))
    }

    public static var isSupported: Bool { VirtualDisplayScaler.isSupported }

    public var isBusy: Bool {
        switch state {
        case .applying, .awaitingConfirmation: true
        case .off, .active: false
        }
    }

    public var savedPreference: VirtualScalingPreference? { try? preferenceStore.load() }

    // MARK: - Trial

    /// Applies `plan` to `display` and starts the confirmation countdown.
    public func beginTrial(on display: DisplayInfo, plan: VirtualScalingPlan) async {
        guard !isBusy else { return }
        guard state.session == nil else {
            finish(.failed("Turn off the current virtual scaling before trying another size."))
            return
        }
        guard let previous = display.currentMode else {
            finish(.failed("The monitor's current mode could not be read, so nothing was changed."))
            return
        }
        let trialID = UUID()
        let started = Date()
        var journal = TrialJournal(
            trialID: trialID, state: .pending, appPID: getpid(), displayKey: display.key,
            displayID: display.id, displayName: display.displayName, previous: previous, target: plan.modeInfo,
            startedAt: started, deadline: started.addingTimeInterval(confirmationTimeout + 15), updatedAt: started,
            note: "Virtual display scaling \(plan.target)")
        do {
            try journalStore.save(journal)
        } catch {
            finish(.failed("The recovery journal could not be written, so nothing was changed. \(error.localizedDescription)"))
            return
        }
        if guardLauncher?.launch(
            journalURL: journalStore.url, parentPID: getpid(), trialID: trialID,
            grace: guardGrace, logURL: guardLogURL) != true {
            Log.virtual.notice("Virtual trial running without a watchdog; process exit still removes the display")
        }
        state = .applying
        record(.trialStarted, display: display.displayName, key: display.key, from: previous, plan: plan,
               detail: "Virtual display \(plan.summary), pending confirmation")

        let session: VirtualScalingSession
        do {
            session = try await scaler.activate(on: display, plan: plan)
        } catch {
            close(&journal, .reverted, note: error.localizedDescription)
            record(.applyFailed, display: display.displayName, key: display.key, from: previous, plan: plan,
                   detail: error.localizedDescription)
            state = .off
            finish(.failed(error.localizedDescription))
            return
        }

        let deadline = Date().addingTimeInterval(confirmationTimeout)
        journal.deadline = deadline
        close(&journal, .pending, note: "Awaiting confirmation")
        state = .awaitingConfirmation(session, deadline: deadline)
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.turnOff(reason: "Not confirmed in time", automatic: true)
        }
    }

    public func keep() {
        guard case .awaitingConfirmation(let session, _) = state else { return }
        timerTask?.cancel()
        closeJournal(session, .kept, note: "Kept by the user")
        try? preferenceStore.save(VirtualScalingPreference(
            displayKey: session.physicalKey, displayName: session.physicalName,
            percent: session.plan.target.percent, savedAt: Date()))
        record(.kept, display: session.physicalName, key: session.physicalKey, from: session.previousMode,
               plan: session.plan, detail: "Virtual display scaling kept; re-applied when ScaleKit starts")
        state = .active(session)
        onOutcome?(.kept(session))
    }

    /// Ends a trial or active scaling. A user-initiated turn-off also forgets
    /// the saved preference.
    public func turnOff(reason: String = "Turned off by the user", automatic: Bool = false, forget: Bool = true) async {
        guard let session = state.session else { return }
        let wasTrial = isBusy
        timerTask?.cancel()
        state = .applying
        await scaler.deactivate()
        if wasTrial { closeJournal(session, .reverted, note: reason) }
        if forget && !automatic { try? preferenceStore.delete() }
        record(automatic ? .autoReverted : .reverted, display: session.physicalName, key: session.physicalKey,
               from: session.previousMode, plan: session.plan, detail: reason)
        state = .off
        onOutcome?(.turnedOff(session, reason: reason, automatic: automatic))
    }

    // MARK: - Events

    /// Turns scaling off when the monitor is really gone. A mirrored display
    /// can report reconfiguration flags without going offline, so this
    /// re-checks after a short delay.
    public func displayRemoved(_ displayID: UInt32) async {
        guard let session = state.session, session.physicalID == displayID else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard CGDisplayIsOnline(displayID) == 0, state.session?.id == session.id else { return }
        await turnOff(reason: "\(session.physicalName) was disconnected", automatic: true, forget: false)
    }

    public func systemWillSleep() async {
        guard isBusy else { return }
        await turnOff(reason: "The Mac went to sleep before the change was confirmed", automatic: true)
    }

    public func systemDidWake() async {
        await checkMirrorAfterReconfiguration()
    }

    /// After wake or a display reconfiguration. A dropped mirror, a re-applied
    /// refresh/VRR setting or moved neighbours are repaired. If the user
    /// reversed the mirror (System Settings ▸ Displays ▸ "Optimise for"),
    /// scaling is turned off rather than fighting that choice, and the
    /// virtual display gets a new identity so the setting macOS saved for it
    /// is not re-applied next time.
    public func checkMirrorAfterReconfiguration() async {
        guard let session = state.session, !isApplying else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard state.session?.id == session.id, !isApplying else { return }
        var mirror = scaler.mirrorState()
        if mirror == .notMirrored || mirror == .scaling {
            mirror = await scaler.repairIfNeeded()
            if mirror == .notMirrored {
                try? await Task.sleep(for: .milliseconds(800))
                mirror = scaler.mirrorState()
            }
        }
        guard state.session?.id == session.id else { return }
        switch mirror {
        case .reversed:
            bumpIdentity()
            await turnOff(
                reason: "The mirror was reversed outside ScaleKit (for example \"Optimise for\" in System Settings ▸ Displays), so the desktop was no longer scaled. Avoid changing that monitor in Displays settings while scaling is on",
                automatic: true, forget: false)
        case .notMirrored:
            await turnOff(reason: "macOS stopped mirroring the monitor and it could not be restored", automatic: true, forget: false)
        case .scaling, .inactive, .monitorOffline:
            break
        }
    }

    private var isApplying: Bool {
        if case .applying = state { return true }
        return false
    }

    /// Call before the app quits. macOS removes the virtual display anyway;
    /// this keeps the journal accurate.
    public func prepareForTermination() {
        timerTask?.cancel()
        if case .awaitingConfirmation(let session, _) = state {
            closeJournal(session, .reverted, note: "ScaleKit quit before confirmation")
        }
    }

    // MARK: - Launch and reconnect

    /// Closes a journal left by a crash, then re-applies saved scaling.
    /// Returns a message for the user, if any.
    public func restoreAtLaunch(displays: [DisplayInfo], refreshRate: (DisplayInfo) -> Double) async -> String? {
        var message: String?
        var skipReapply = false
        if var journal = try? journalStore.load(),
           VirtualTrialLaunchPolicy.needsClosing(journal, currentPID: getpid(), isProcessAlive: isProcessAlive) {
            if journal.note == Self.reapplyNote {
                // ScaleKit died while re-applying: don't risk a crash loop.
                skipReapply = true
                message = "ScaleKit quit unexpectedly while re-applying saved scaling last time, so it was not re-applied now. Choose the size again to retry."
            } else {
                message = "An unconfirmed virtual-display change was undone when ScaleKit exited."
            }
            close(&journal, .revertedBySystem, note: "ScaleKit exited; macOS removed the virtual display")
        }
        guard !skipReapply else { return message }
        return await restoreSaved(displays: displays, refreshRate: refreshRate) ?? message
    }

    /// Re-applies the kept size when its monitor is connected and nothing
    /// else is running. Used at launch and when the monitor reconnects.
    @discardableResult
    public func restoreSaved(displays: [DisplayInfo], refreshRate: (DisplayInfo) -> Double) async -> String? {
        guard Self.isSupported, case .off = state, let preference = savedPreference,
              let display = displays.first(where: { $0.key == preference.displayKey }),
              let previous = display.currentMode,
              let native = display.nativeResolution.value,
              let plan = VirtualScalingPlan(
                target: ScalingTarget(percent: preference.percent), native: native, refreshRate: refreshRate(display))
        else { return nil }
        let now = Date()
        var journal = TrialJournal(
            trialID: UUID(), state: .pending, appPID: getpid(), displayKey: display.key, displayID: display.id,
            displayName: display.displayName, previous: previous, target: plan.modeInfo, startedAt: now,
            deadline: now.addingTimeInterval(3600), updatedAt: now, note: Self.reapplyNote)
        try? journalStore.save(journal)
        state = .applying
        do {
            let session = try await scaler.activate(on: display, plan: plan)
            close(&journal, .kept, note: "Re-applied saved scaling")
            record(.kept, display: display.displayName, key: display.key, from: previous, plan: plan,
                   detail: "Saved virtual scaling re-applied")
            state = .active(session)
            onOutcome?(.restoredAtLaunch(session))
            return nil
        } catch {
            close(&journal, .reverted, note: error.localizedDescription)
            record(.applyFailed, display: display.displayName, key: display.key, from: previous, plan: plan,
                   detail: "Saved virtual scaling could not be re-applied: \(error.localizedDescription)")
            state = .off
            return "Saved \(preference.percent)% virtual scaling could not be re-applied: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func virtualDisplayVanished(_ session: VirtualScalingSession) {
        timerTask?.cancel()
        if isBusy { closeJournal(session, .revertedBySystem, note: "macOS removed the virtual display") }
        record(.autoReverted, display: session.physicalName, key: session.physicalKey, from: session.previousMode,
               plan: session.plan, detail: "macOS removed the virtual display")
        state = .off
        onOutcome?(.turnedOff(session, reason: "macOS removed the virtual display", automatic: true))
    }

    private func finish(_ outcome: Outcome) {
        onOutcome?(outcome)
    }

    private func close(_ journal: inout TrialJournal, _ newState: TrialJournal.State, note: String) {
        journal.state = newState
        journal.note = note
        journal.updatedAt = Date()
        try? journalStore.save(journal)
    }

    private func closeJournal(_ session: VirtualScalingSession, _ newState: TrialJournal.State, note: String) {
        guard var journal = try? journalStore.load(), journal.state == .pending,
              journal.displayKey == session.physicalKey
        else { return }
        close(&journal, newState, note: note)
    }

    private func record(
        _ kind: HistoryEntry.Kind, display: String, key: String, from: DisplayModeInfo?,
        plan: VirtualScalingPlan, detail: String
    ) {
        history.append(HistoryEntry(
            date: Date(), kind: kind, displayName: display, displayKey: key,
            from: from?.signature, to: plan.modeInfo.signature, detail: "[Virtual \(plan.target)] \(detail)"))
    }
}

/// The generation used for virtual-display identities (see `bumpIdentity`).
private struct VirtualIdentityState: Codable {
    var generation: UInt32
}
