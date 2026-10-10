import Foundation
@testable import ScaleKitCore

/// In-memory stand-in for CoreGraphics/AppKit/IOKit. Never touches real displays.
@MainActor
final class FakeDisplayHardware: DisplayHardware {
    struct ApplyCall: Equatable, Sendable {
        var modeID: Int32
        var displayID: UInt32
        var scope: ConfigurationScope
    }

    private(set) var monitors: [UInt32: MonitorFixture] = [:]
    private var order: [UInt32] = []
    private var currentModeIDs: [UInt32: Int32] = [:]
    /// The mode `restorePermanentConfiguration()` returns each display to.
    private var permanentModeIDs: [UInt32: Int32] = [:]

    private(set) var applyCalls: [ApplyCall] = []
    private(set) var restorePermanentCount = 0

    /// Thrown by `applyMode` for calls whose scope is in `failingScopes` (every call when nil).
    var applyError: (any Error)?
    var failingScopes: Set<ConfigurationScope>?
    /// Accept `applyMode` calls without changing the active mode (a driver that silently ignores requests).
    var ignoresApply = false
    /// When false, AppKit reports no screens at all.
    var reportsScreens = true
    var hiddenScreens: Set<UInt32> = []
    var registry: [RegistryDisplayAttributes] = []
    /// Called at the start of every `applyMode`, before anything changes.
    var onApply: (@MainActor (ApplyCall) -> Void)?

    init(monitors: [MonitorFixture] = [Fixtures.asus, Fixtures.msi]) {
        for monitor in monitors { connect(monitor) }
    }

    // MARK: Test controls

    func connect(_ monitor: MonitorFixture) {
        monitors[monitor.displayID] = monitor
        if !order.contains(monitor.displayID) { order.append(monitor.displayID) }
        currentModeIDs[monitor.displayID] = monitor.currentModeID
        permanentModeIDs[monitor.displayID] = monitor.currentModeID
    }

    func disconnect(_ displayID: UInt32) {
        order.removeAll { $0 == displayID }
    }

    /// Simulates another app or System Settings changing the mode.
    func setCurrentMode(_ modeID: Int32?, on displayID: UInt32) {
        currentModeIDs[displayID] = modeID
    }

    func currentModeID(on displayID: UInt32) -> Int32? {
        currentModeIDs[displayID]
    }

    func permanentModeID(on displayID: UInt32) -> Int32? {
        permanentModeIDs[displayID]
    }

    // MARK: DisplayHardware

    func onlineDisplayIDs() -> [UInt32] {
        order
    }

    func rawInfo(for displayID: UInt32) -> RawDisplayInfo? {
        guard order.contains(displayID), let monitor = monitors[displayID] else { return nil }
        return monitor.raw(current: currentMode(for: displayID))
    }

    func currentMode(for displayID: UInt32) -> DisplayModeInfo? {
        guard order.contains(displayID), let monitor = monitors[displayID],
              let id = currentModeIDs[displayID] else { return nil }
        return monitor.modes.first { $0.modeID == id }
    }

    func allModes(for displayID: UInt32, includeLowResolutionDuplicates: Bool) -> [DisplayModeInfo] {
        guard order.contains(displayID), let monitor = monitors[displayID] else { return [] }
        return includeLowResolutionDuplicates ? monitor.modes : monitor.modes.filter { !$0.isHiDPI }
    }

    func applyMode(modeID: Int32, to displayID: UInt32, scope: ConfigurationScope) throws {
        let call = ApplyCall(modeID: modeID, displayID: displayID, scope: scope)
        applyCalls.append(call)
        onApply?(call)
        if let applyError, failingScopes?.contains(scope) ?? true {
            throw applyError
        }
        guard order.contains(displayID), let monitor = monitors[displayID] else {
            throw DisplayHardwareError.displayNotFound(displayID)
        }
        guard monitor.modes.contains(where: { $0.modeID == modeID }) else {
            throw DisplayHardwareError.modeNotFound(displayID: displayID, modeID: modeID)
        }
        if ignoresApply { return }
        currentModeIDs[displayID] = modeID
        if scope == .permanent { permanentModeIDs[displayID] = modeID }
    }

    func restorePermanentConfiguration() {
        restorePermanentCount += 1
        for (displayID, modeID) in permanentModeIDs {
            currentModeIDs[displayID] = modeID
        }
    }

    func screenSnapshots() -> [ScreenSnapshot] {
        guard reportsScreens else { return [] }
        return order.compactMap { id in
            guard !hiddenScreens.contains(id), let monitor = monitors[id], let mode = currentMode(for: id) else {
                return nil
            }
            return monitor.screen(for: mode)
        }
    }

    func registryAttributes() -> [RegistryDisplayAttributes] {
        registry
    }
}

/// Records watchdog launches instead of starting a process.
final class FakeGuardLauncher: GuardLauncher, @unchecked Sendable {
    struct Launch: Equatable, Sendable {
        var journalURL: URL
        var parentPID: Int32
        var trialID: UUID
        var grace: TimeInterval
        var logURL: URL
    }

    private let lock = NSLock()
    private var recorded: [Launch] = []
    private let result: Bool

    init(result: Bool = true) {
        self.result = result
    }

    var launches: [Launch] {
        lock.withLock { recorded }
    }

    func launch(journalURL: URL, parentPID: Int32, trialID: UUID, grace: TimeInterval, logURL: URL) -> Bool {
        lock.withLock {
            recorded.append(Launch(
                journalURL: journalURL, parentPID: parentPID, trialID: trialID, grace: grace, logURL: logURL))
        }
        return result
    }
}

/// A fully wired `ScaleKitServices` over fake hardware and a temporary support directory.
@MainActor
final class ServicesHarness {
    let tmp: TemporaryDirectory
    let fake: FakeDisplayHardware
    let launcher: FakeGuardLauncher
    let services: ScaleKitServices

    var recovery: RecoveryService { services.recovery }
    var paths: AppPaths { services.paths }

    init(
        monitors: [MonitorFixture] = [Fixtures.asus, Fixtures.msi],
        unwritableRoot: Bool = false,
        guardResult: Bool = true,
        confirmationTimeout: TimeInterval = 30
    ) throws {
        tmp = try TemporaryDirectory()
        fake = FakeDisplayHardware(monitors: monitors)
        launcher = FakeGuardLauncher(result: guardResult)
        let root = unwritableRoot
            ? try tmp.unwritableDirectory()
            : tmp.url.appendingPathComponent("Support", isDirectory: true)
        services = ScaleKitServices(
            hardware: fake, paths: AppPaths(root: root), guardLauncher: launcher, environment: .testFixture)
        services.configuration.verificationTimeout = .milliseconds(300)
        services.configuration.pollInterval = .milliseconds(20)
        services.recovery.confirmationTimeout = confirmationTimeout
    }

    func cleanup() {
        tmp.cleanup()
    }

    func display(_ id: UInt32 = Fixtures.asus.displayID) -> DisplayInfo? {
        services.discovery.display(withID: id)
    }

    func historyKinds() -> [HistoryEntry.Kind] {
        services.history.entries().map(\.kind)
    }

    func writeJournal(_ journal: TrialJournal) throws {
        try JSONFileStore<TrialJournal>(url: paths.trialJournalFile).save(journal)
    }
}

extension RecoveryService.State {
    var outcome: RecoveryService.Outcome? {
        if case .finished(let outcome) = self { return outcome }
        return nil
    }

    var isFinished: Bool { outcome != nil }
}
