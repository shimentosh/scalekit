import Foundation

// MARK: - Rollback decisions (pure)

/// Something that happened while a change was waiting for confirmation.
public enum TrialEvent: Sendable, Equatable {
    case userKept
    case userReverted
    case timerExpired
    case targetDisplayRemoved
    /// Another app or System Settings changed the display's mode.
    case targetDisplayChangedExternally
    case systemWillSleep
    case appTerminating
}

public enum TrialPhase: Sendable, Equatable {
    case idle, applying, awaitingConfirmation, finished
}

public enum RollbackDecision: Sendable, Equatable {
    case keep
    case revert(reason: String)
    /// The display is gone; nothing can be restored right now.
    case abandon(reason: String)
    /// Someone else changed the display; stop without touching it.
    case supersede(reason: String)
    case ignore
}

public enum RollbackPolicy {
    public static func decide(_ event: TrialEvent, phase: TrialPhase) -> RollbackDecision {
        guard phase == .awaitingConfirmation else { return .ignore }
        switch event {
        case .userKept:
            return .keep
        case .userReverted:
            return .revert(reason: "You chose Revert.")
        case .timerExpired:
            return .revert(reason: "The change was not confirmed in time.")
        case .systemWillSleep:
            return .revert(reason: "The Mac went to sleep before the change was confirmed.")
        case .appTerminating:
            return .revert(reason: "ScaleKit quit before the change was confirmed.")
        case .targetDisplayRemoved:
            return .abandon(reason: "The display was disconnected before the change was confirmed.")
        case .targetDisplayChangedExternally:
            return .supersede(reason: "The display's mode was changed outside ScaleKit.")
        }
    }
}

/// What to do about a trial journal found at launch.
public enum LaunchAssessment: Sendable, Equatable {
    case nothingToDo
    /// Another running ScaleKit process owns the trial.
    case ownedByRunningInstance(pid: Int32)
    case displayMissing
    /// The pre-change mode is active: macOS already reverted the app-only change.
    case previousModeActive
    /// The unconfirmed mode is still active and must be undone.
    case trialModeStillActive
    /// Neither mode is active; something else changed the display.
    case otherModeActive
}

public enum LaunchRecoveryPolicy {
    public static func assess(
        journal: TrialJournal?,
        currentPID: Int32,
        isProcessAlive: (Int32) -> Bool,
        currentMode: DisplayModeInfo?,
        displayConnected: Bool
    ) -> LaunchAssessment {
        guard let journal, journal.state == .pending || journal.state == .abandoned else { return .nothingToDo }
        if journal.state == .pending, journal.appPID != currentPID, isProcessAlive(journal.appPID) {
            return .ownedByRunningInstance(pid: journal.appPID)
        }
        guard displayConnected else { return .displayMissing }
        switch currentMode?.signature {
        case journal.previous.signature: return .previousModeActive
        case journal.target.signature: return .trialModeStillActive
        default: return .otherModeActive
        }
    }
}

public struct LaunchRecoveryReport: Sendable, Equatable {
    public var journal: TrialJournal
    public var assessment: LaunchAssessment
    public var message: String
}

// MARK: - Watchdog

/// Starts the watchdog process that protects a trial if ScaleKit hangs.
public protocol GuardLauncher: Sendable {
    func launch(journalURL: URL, parentPID: Int32, trialID: UUID, grace: TimeInterval, logURL: URL) -> Bool
}

/// Launches the bundled `ScaleKitGuard` executable. No privileges are needed:
/// it runs as the same user and only uses public CoreGraphics calls.
public struct ProcessGuardLauncher: GuardLauncher {
    public let executableURL: URL

    public init(executableURL: URL) { self.executableURL = executableURL }

    /// Looks for `ScaleKitGuard` next to the running executable, or in the
    /// bundle's `Contents/MacOS` when running from `Contents/Helpers`.
    public static func locate() -> ProcessGuardLauncher? {
        guard let directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        else { return nil }
        let candidates = [
            directory.appendingPathComponent("ScaleKitGuard"),
            directory.deletingLastPathComponent().appendingPathComponent("MacOS/ScaleKitGuard"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            .map(ProcessGuardLauncher.init(executableURL:))
    }

    public func launch(journalURL: URL, parentPID: Int32, trialID: UUID, grace: TimeInterval, logURL: URL) -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--journal", journalURL.path, "--parent", String(parentPID), "--trial", trialID.uuidString,
            "--grace", String(grace), "--log", logURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            Log.recovery.info("Started guard process \(process.processIdentifier)")
            return true
        } catch {
            Log.recovery.error("Could not start guard: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

public func isProcessAlive(_ pid: Int32) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
}

// MARK: - Recovery service

/// Applies display changes as reversible trials and restores the previous
/// configuration when they are not confirmed.
///
/// Safety layers, in order:
/// 1. The previous mode is saved to disk before anything changes.
/// 2. A journal is written so a crash or restart can be detected at launch.
/// 3. The trial is applied with `kCGConfigureForAppOnly`, which WindowServer
///    reverts automatically when this process exits for any reason.
/// 4. A countdown reverts the change unless the user presses Keep.
/// 5. A watchdog process terminates ScaleKit if it hangs past the deadline,
///    which triggers step 3.
@MainActor
public final class RecoveryService {
    public struct Session: Sendable, Equatable {
        public var id: UUID
        public var displayID: UInt32
        public var displayKey: String
        public var displayName: String
        public var previous: DisplayModeInfo
        public var target: DisplayModeInfo
        public var startedAt: Date
        public var deadline: Date
        public var verification: ApplyVerification

        public init(
            id: UUID, displayID: UInt32, displayKey: String, displayName: String,
            previous: DisplayModeInfo, target: DisplayModeInfo, startedAt: Date, deadline: Date,
            verification: ApplyVerification
        ) {
            self.id = id
            self.displayID = displayID
            self.displayKey = displayKey
            self.displayName = displayName
            self.previous = previous
            self.target = target
            self.startedAt = startedAt
            self.deadline = deadline
            self.verification = verification
        }
    }

    public enum Outcome: Sendable, Equatable {
        case kept(Session, ApplyVerification)
        case reverted(Session, reason: String, restored: ApplyVerification?)
        case failed(message: String, restored: ApplyVerification?)
        case abandoned(Session, reason: String)
        case superseded(Session, reason: String)
    }

    public enum State: Sendable, Equatable {
        case idle
        case applying(displayID: UInt32)
        case awaitingConfirmation(Session)
        case finished(Outcome)

        public var phase: TrialPhase {
            switch self {
            case .idle: .idle
            case .applying: .applying
            case .awaitingConfirmation: .awaitingConfirmation
            case .finished: .finished
            }
        }

        public var session: Session? {
            if case .awaitingConfirmation(let session) = self { return session }
            return nil
        }
    }

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    public var onStateChange: (@MainActor (State) -> Void)?
    /// Seconds the user has to press Keep.
    public var confirmationTimeout: TimeInterval = 15
    /// Extra seconds the watchdog waits after the deadline before acting.
    public var guardGrace: TimeInterval = 8

    private let configuration: DisplayConfigurationService
    private let modes: DisplayModeService
    private let backups: ConfigurationBackupService
    private let history: HistoryStore
    private let verifications: VerificationStore
    private let journalStore: JSONFileStore<TrialJournal>
    private let guardLauncher: GuardLauncher?
    private let guardLogURL: URL
    private let environment: EnvironmentInfo
    private let now: () -> Date
    private var timerTask: Task<Void, Never>?

    public init(
        configuration: DisplayConfigurationService,
        modes: DisplayModeService,
        backups: ConfigurationBackupService,
        history: HistoryStore,
        verifications: VerificationStore,
        journalURL: URL,
        guardLauncher: GuardLauncher?,
        guardLogURL: URL,
        environment: EnvironmentInfo,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.modes = modes
        self.backups = backups
        self.history = history
        self.verifications = verifications
        self.journalStore = JSONFileStore(url: journalURL)
        self.guardLauncher = guardLauncher
        self.guardLogURL = guardLogURL
        self.environment = environment
        self.now = now
    }

    public var isBusy: Bool {
        switch state {
        case .applying, .awaitingConfirmation: true
        case .idle, .finished: false
        }
    }

    /// Backs up, applies `target` for this process only, verifies it and starts
    /// the confirmation countdown.
    @discardableResult
    public func beginTrial(
        on display: DisplayInfo, to target: DisplayModeInfo, acceptRefreshReduction: Bool = false
    ) async -> State {
        guard !isBusy else { return state }

        let plan = configuration.plan(for: display, target: target)
        guard plan.validation.isValid else {
            state = .finished(.failed(message: plan.validation.errors.joined(separator: " "), restored: nil))
            return state
        }
        if plan.validation.requiresRefreshConfirmation && !acceptRefreshReduction {
            state = .finished(.failed(
                message: "\(plan.refresh.summary). Confirm the refresh-rate reduction to continue.", restored: nil))
            return state
        }
        guard let backup = backups.capture(display) else {
            state = .finished(.failed(message: "The current mode could not be read, so nothing was changed.", restored: nil))
            return state
        }
        do {
            try backups.save(backup)
        } catch {
            state = .finished(.failed(
                message: "The current configuration could not be backed up, so nothing was changed. \(error.localizedDescription)",
                restored: nil))
            return state
        }
        record(.backupSaved, display: display, from: backup.mode, to: nil, detail: "Saved \(backup.mode.summary)")

        let trialID = UUID()
        let started = now()
        // Provisional deadline covering verification; replaced once the mode is confirmed.
        var journal = TrialJournal(
            trialID: trialID, state: .pending, appPID: getpid(), displayKey: display.key,
            displayID: display.id, displayName: display.displayName, previous: backup.mode, target: target,
            startedAt: started,
            deadline: started.addingTimeInterval(confirmationTimeout + 10),
            updatedAt: started)
        do {
            try journalStore.save(journal)
        } catch {
            state = .finished(.failed(
                message: "The recovery journal could not be written, so nothing was changed. \(error.localizedDescription)",
                restored: nil))
            return state
        }
        let guardStarted = guardLauncher?.launch(
            journalURL: journalStore.url, parentPID: getpid(), trialID: trialID,
            grace: guardGrace, logURL: guardLogURL) ?? false
        if !guardStarted {
            Log.recovery.notice("Trial running without a watchdog; app-only revert still applies")
        }

        state = .applying(displayID: display.id)
        record(.trialStarted, display: display, from: backup.mode, to: target, detail: "Applied for this session only, pending confirmation")

        let verification: ApplyVerification
        do {
            verification = try await configuration.apply(target, to: display.id, scope: .appOnly)
        } catch {
            let restored = await restoreIfNeeded(backup.mode, displayID: display.id)
            updateJournal(&journal, .reverted, note: error.localizedDescription)
            record(.applyFailed, display: display, from: backup.mode, to: target, detail: error.localizedDescription)
            state = .finished(.failed(message: error.localizedDescription, restored: restored))
            return state
        }

        guard verification.level != .failed else {
            let restored = await restoreIfNeeded(backup.mode, displayID: display.id)
            let message = "The display did not switch to \(target.summary). " + verification.notes.joined(separator: " ")
            updateJournal(&journal, .reverted, note: message)
            record(.verificationFailed, display: display, from: backup.mode, to: target, detail: message)
            state = .finished(.failed(message: message, restored: restored))
            return state
        }

        if verification.level == .verified {
            verifications.record(VerificationRecord(
                displayKey: display.key, displayName: display.displayName, signature: target.signature,
                verifiedAt: now(), osVersion: environment.summary,
                hardwareModel: environment.hardwareModel ?? "unknown",
                observedScale: verification.screenScale.value,
                method: "CGDisplayCopyDisplayMode + NSScreen.backingScaleFactor/frame"))
        }

        let deadline = now().addingTimeInterval(confirmationTimeout)
        journal.deadline = deadline
        updateJournal(&journal, .pending, note: "Awaiting confirmation")

        let session = Session(
            id: trialID, displayID: display.id, displayKey: display.key, displayName: display.displayName,
            previous: backup.mode, target: target, startedAt: started, deadline: deadline,
            verification: verification)
        state = .awaitingConfirmation(session)
        startTimer(until: deadline)
        return state
    }

    /// Feeds an event through `RollbackPolicy` and acts on the decision.
    public func handle(_ event: TrialEvent) async {
        guard let session = state.session else { return }
        switch RollbackPolicy.decide(event, phase: state.phase) {
        case .keep:
            await keep(session)
        case .revert(let reason):
            await revert(session, reason: reason, automatic: event != .userReverted)
        case .abandon(let reason):
            timerTask?.cancel()
            updateJournal(session, .abandoned, note: reason)
            record(.abandoned, session: session, detail: reason)
            state = .finished(.abandoned(session, reason: reason))
        case .supersede(let reason):
            timerTask?.cancel()
            updateJournal(session, .superseded, note: reason)
            record(.superseded, session: session, detail: reason)
            state = .finished(.superseded(session, reason: reason))
        case .ignore:
            break
        }
    }

    public func keep() async { await handle(.userKept) }
    public func revert() async { await handle(.userReverted) }

    /// Called synchronously from `applicationWillTerminate`. WindowServer
    /// reverts the app-only change as the process exits; this records why.
    public func prepareForTermination() {
        guard let session = state.session else { return }
        timerTask?.cancel()
        updateJournal(session, .revertedBySystem, note: "ScaleKit quit before confirmation; macOS reverts app-only changes at exit.")
        record(.autoReverted, session: session, detail: "ScaleKit quit before the change was confirmed.")
    }

    /// Checks for a trial left unfinished by a crash, force quit, hang or restart.
    public func recoverAfterLaunch(displays: [DisplayInfo]) async -> LaunchRecoveryReport? {
        guard var journal = try? journalStore.load() else { return nil }
        let display = displays.first { $0.key == journal.displayKey }
        let assessment = LaunchRecoveryPolicy.assess(
            journal: journal, currentPID: getpid(), isProcessAlive: isProcessAlive,
            currentMode: display?.currentMode, displayConnected: display != nil)

        let message: String
        switch assessment {
        case .nothingToDo, .ownedByRunningInstance:
            return nil
        case .displayMissing:
            journal.state = .abandoned
            message = "\(journal.displayName) is not connected. ScaleKit will check it again when it reconnects."
        case .previousModeActive:
            journal.state = .revertedBySystem
            message = "An unconfirmed change to \(journal.displayName) was undone by macOS. \(journal.previous.summary) is active."
            history.append(HistoryEntry(
                date: now(), kind: .recovered, displayName: journal.displayName, displayKey: journal.displayKey,
                from: journal.target.signature, to: journal.previous.signature, detail: message))
        case .trialModeStillActive:
            guard let display else { return nil }
            let restored = await restoreIfNeeded(journal.previous, displayID: display.id, scope: .permanent)
            journal.state = .reverted
            message = restored?.level == .failed || restored == nil
                ? "An unconfirmed change to \(journal.displayName) was still active and could not be undone automatically."
                : "An unconfirmed change to \(journal.displayName) was still active. ScaleKit restored \(journal.previous.summary)."
            history.append(HistoryEntry(
                date: now(), kind: .recovered, displayName: journal.displayName, displayKey: journal.displayKey,
                from: journal.target.signature, to: journal.previous.signature, detail: message))
        case .otherModeActive:
            journal.state = .superseded
            message = "\(journal.displayName) is in a mode that ScaleKit did not set, so it was left unchanged."
        }
        journal.updatedAt = now()
        journal.note = message
        try? journalStore.save(journal)
        Log.recovery.notice("Launch recovery: \(message, privacy: .public)")
        return LaunchRecoveryReport(journal: journal, assessment: assessment, message: message)
    }

    public func currentJournal() -> TrialJournal? {
        try? journalStore.load()
    }

    // MARK: - Private

    private func keep(_ session: Session) async {
        timerTask?.cancel()
        state = .applying(displayID: session.displayID)
        do {
            let verification = try await configuration.apply(session.target, to: session.displayID, scope: .permanent)
            guard verification.level != .failed else {
                await revert(session, reason: "The mode could not be saved permanently. " + verification.notes.joined(separator: " "), automatic: true)
                return
            }
            updateJournal(session, .kept, note: "Saved permanently")
            record(.kept, session: session, detail: "Saved to display preferences")
            state = .finished(.kept(session, verification))
        } catch {
            await revert(session, reason: "The mode could not be saved permanently: \(error.localizedDescription)", automatic: true)
        }
    }

    private func revert(_ session: Session, reason: String, automatic: Bool) async {
        timerTask?.cancel()
        state = .applying(displayID: session.displayID)
        let restored = await restoreIfNeeded(session.previous, displayID: session.displayID)
        let detail = reason + (restored.map { " Restored: \($0.level.rawValue)." } ?? " Previous mode was already active.")
        updateJournal(session, .reverted, note: detail)
        record(automatic ? .autoReverted : .reverted, session: session, detail: detail)
        state = .finished(.reverted(session, reason: reason, restored: restored))
    }

    /// Restores `previous` if it is not already active. Falls back to the saved
    /// permanent configuration if the mode can no longer be found or applied.
    private func restoreIfNeeded(
        _ previous: DisplayModeInfo, displayID: UInt32, scope: ConfigurationScope = .appOnly
    ) async -> ApplyVerification? {
        if modes.currentMode(for: displayID)?.signature == previous.signature { return nil }
        if let mode = modes.mode(matching: previous.signature, for: displayID),
           let result = try? await configuration.apply(mode, to: displayID, scope: scope),
           result.level != .failed {
            return result
        }
        Log.recovery.error("Direct restore failed; restoring the permanent configuration")
        configuration.hardware.restorePermanentConfiguration()
        return await configuration.verify(previous, on: displayID)
    }

    private func startTimer(until deadline: Date) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            let interval = deadline.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
            guard !Task.isCancelled else { return }
            await self?.handle(.timerExpired)
        }
    }

    private func updateJournal(_ journal: inout TrialJournal, _ newState: TrialJournal.State, note: String) {
        journal.state = newState
        journal.updatedAt = now()
        journal.note = note
        do {
            try journalStore.save(journal)
        } catch {
            Log.recovery.error("Could not update journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateJournal(_ session: Session, _ newState: TrialJournal.State, note: String) {
        guard var journal = try? journalStore.load(), journal.trialID == session.id else { return }
        updateJournal(&journal, newState, note: note)
    }

    private func record(
        _ kind: HistoryEntry.Kind, display: DisplayInfo, from: DisplayModeInfo?, to: DisplayModeInfo?, detail: String
    ) {
        history.append(HistoryEntry(
            date: now(), kind: kind, displayName: display.displayName, displayKey: display.key,
            from: from?.signature, to: to?.signature, detail: detail))
    }

    private func record(_ kind: HistoryEntry.Kind, session: Session, detail: String) {
        history.append(HistoryEntry(
            date: now(), kind: kind, displayName: session.displayName, displayKey: session.displayKey,
            from: session.previous.signature, to: session.target.signature, detail: detail))
    }
}
