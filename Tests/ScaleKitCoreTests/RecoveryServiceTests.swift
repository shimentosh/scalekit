import Foundation
import Testing
@testable import ScaleKitCore

/// End-to-end trials over `FakeDisplayHardware`. No real display is touched.
@MainActor
@Suite("Recovery service", .serialized)
struct RecoveryServiceTests {
    let asus = Fixtures.asus
    var previous: DisplayModeInfo { asus.mode(119) }
    var target: DisplayModeInfo { asus.mode(80) }

    /// Starts a trial from 3440×1440 @ 120 Hz to 1720×720 HiDPI @ 120 Hz and requires it to be awaiting confirmation.
    private func startTrial(_ harness: ServicesHarness) async throws -> RecoveryService.Session {
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: target)
        return try #require(state.session, "Expected awaitingConfirmation, got \(state)")
    }

    // MARK: Begin

    @Test("Begin: backs up, journals, starts the guard, applies app-only and awaits confirmation")
    func begin() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let fake = harness.fake
        let display = try #require(harness.display())

        let journalAtApply = Box<TrialJournal?>(nil)
        let backupAtApply = Box<DisplayStateRecord?>(nil)
        let guardsAtApply = Box(-1)
        fake.onApply = { _ in
            journalAtApply.value = harness.recovery.currentJournal()
            backupAtApply.value = harness.services.backups.backup(for: display.key)
            guardsAtApply.value = harness.launcher.launches.count
        }

        let state = await harness.recovery.beginTrial(on: display, to: target)
        let session = try #require(state.session, "state was \(state)")

        // Safety layers were in place before anything changed.
        #expect(journalAtApply.value?.state == .pending)
        #expect(journalAtApply.value?.target == target)
        #expect(backupAtApply.value?.mode == previous)
        #expect(guardsAtApply.value == 1)

        #expect(fake.applyCalls == [.init(modeID: 80, displayID: 3, scope: .appOnly)])
        #expect(fake.currentModeID(on: 3) == 80)
        #expect(fake.permanentModeID(on: 3) == 119, "an app-only trial must not touch the saved configuration")
        #expect(harness.recovery.state.phase == .awaitingConfirmation)
        #expect(harness.recovery.isBusy)

        #expect(session.previous == previous)
        #expect(session.target == target)
        #expect(session.displayKey == display.key)
        #expect(session.verification.level == .verified)
        #expect(session.verification.screenScale.value == 2)
        #expect(session.verification.screenSize.value == PixelSize(width: 1720, height: 720))
        #expect(abs(session.deadline.timeIntervalSince(session.startedAt) - harness.recovery.confirmationTimeout) < 2)

        let journal = try #require(harness.recovery.currentJournal())
        #expect(journal.state == .pending)
        #expect(journal.trialID == session.id)
        #expect(journal.appPID == getpid())
        #expect(journal.previous == previous)
        #expect(journal.target == target)

        #expect(harness.services.backups.backup(for: display.key)?.mode == previous)

        let launch = try #require(harness.launcher.launches.first)
        #expect(launch.trialID == session.id)
        #expect(launch.parentPID == getpid())
        #expect(launch.journalURL == harness.paths.trialJournalFile)
        #expect(launch.logURL == harness.paths.guardLogFile)
        #expect(launch.grace == harness.recovery.guardGrace)

        #expect(harness.historyKinds() == [.trialStarted, .backupSaved])
        #expect(harness.services.verifications.verifiedSignatures(for: display.key) == [target.signature])

        await harness.recovery.revert()
    }

    @Test("State changes are published in order")
    func stateCallbacks() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let phases = Box<[TrialPhase]>([])
        harness.recovery.onStateChange = { phases.value.append($0.phase) }
        _ = try await startTrial(harness)
        await harness.recovery.keep()
        #expect(phases.value == [.applying, .awaitingConfirmation, .applying, .finished])
    }

    @Test("A trial proceeds without a watchdog when the guard cannot start")
    func noGuard() async throws {
        let harness = try ServicesHarness(guardResult: false)
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        #expect(harness.launcher.launches.count == 1)
        #expect(harness.recovery.state.phase == .awaitingConfirmation)
        await harness.recovery.revert()
    }

    @Test("A second trial cannot start while one is awaiting confirmation")
    func busy() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let session = try await startTrial(harness)
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: asus.mode(72))
        #expect(state.session == session)
        #expect(harness.fake.applyCalls.count == 1)
        await harness.recovery.revert()
    }

    // MARK: Keep and revert

    @Test("Keep re-applies permanently, marks the journal kept and records history")
    func keep() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let session = try await startTrial(harness)
        await harness.recovery.keep()

        guard case .finished(.kept(let kept, let verification)) = harness.recovery.state else {
            Issue.record("Expected kept, got \(harness.recovery.state)")
            return
        }
        #expect(kept == session)
        #expect(verification.level == .verified)
        #expect(harness.fake.applyCalls.map(\.scope) == [.appOnly, .permanent])
        #expect(harness.fake.currentModeID(on: 3) == 80)
        #expect(harness.fake.permanentModeID(on: 3) == 80)
        #expect(harness.recovery.currentJournal()?.state == .kept)
        #expect(harness.historyKinds().first == .kept)
        #expect(!harness.recovery.isBusy)
    }

    @Test("Revert restores the previous mode and marks the journal reverted")
    func revert() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let session = try await startTrial(harness)
        await harness.recovery.revert()

        guard case .finished(.reverted(let reverted, let reason, let restored)) = harness.recovery.state else {
            Issue.record("Expected reverted, got \(harness.recovery.state)")
            return
        }
        #expect(reverted == session)
        #expect(reason == "You chose Revert.")
        #expect(restored?.level == .verified)
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(harness.fake.applyCalls.map(\.modeID) == [80, 119])
        #expect(harness.fake.applyCalls.map(\.scope) == [.appOnly, .appOnly])
        #expect(harness.fake.permanentModeID(on: 3) == 119)
        #expect(harness.recovery.currentJournal()?.state == .reverted)
        #expect(harness.historyKinds().first == .reverted)
    }

    @Test("The countdown reverts automatically when nobody confirms")
    func timerExpiry() async throws {
        let harness = try ServicesHarness(confirmationTimeout: 0.3)
        defer { harness.cleanup() }
        _ = try await startTrial(harness)

        let finished = await waitUntil(timeout: .seconds(3)) { harness.recovery.state.isFinished }
        #expect(finished, "The trial did not revert within 3 s")
        guard case .finished(.reverted(_, let reason, let restored)) = harness.recovery.state else {
            Issue.record("Expected reverted, got \(harness.recovery.state)")
            return
        }
        #expect(reason.contains("not confirmed in time"))
        #expect(restored?.level == .verified)
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(harness.recovery.currentJournal()?.state == .reverted)
        #expect(harness.historyKinds().first == .autoReverted)
    }

    @Test("Keep after the countdown has fired changes nothing")
    func keepAfterExpiry() async throws {
        let harness = try ServicesHarness(confirmationTimeout: 0.2)
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        #expect(await waitUntil { harness.recovery.state.isFinished })
        let calls = harness.fake.applyCalls
        await harness.recovery.keep()
        #expect(harness.fake.applyCalls == calls)
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(harness.recovery.currentJournal()?.state == .reverted)
    }

    @Test("Keep cancels the countdown")
    func keepCancelsTimer() async throws {
        let harness = try ServicesHarness(confirmationTimeout: 0.3)
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        await harness.recovery.keep()
        try await Task.sleep(for: .milliseconds(600))
        guard case .finished(.kept) = harness.recovery.state else {
            Issue.record("Expected kept, got \(harness.recovery.state)")
            return
        }
        #expect(harness.fake.currentModeID(on: 3) == 80)
        #expect(harness.fake.applyCalls.count == 2)
    }

    @Test("If saving permanently fails, the trial is reverted automatically")
    func keepFails() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        harness.fake.applyError = DisplayHardwareError.coreGraphics(operation: "CGCompleteDisplayConfiguration", code: 1004)
        harness.fake.failingScopes = [.permanent]
        await harness.recovery.keep()

        guard case .finished(.reverted(_, let reason, let restored)) = harness.recovery.state else {
            Issue.record("Expected reverted, got \(harness.recovery.state)")
            return
        }
        #expect(reason.contains("could not be saved permanently"))
        #expect(restored?.level == .verified)
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(harness.fake.permanentModeID(on: 3) == 119)
        #expect(harness.historyKinds().first == .autoReverted)
    }

    @Test("If the direct restore fails, the saved permanent configuration is restored")
    func restoreFallback() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        harness.fake.ignoresApply = true
        await harness.recovery.revert()

        guard case .finished(.reverted(_, _, let restored)) = harness.recovery.state else {
            Issue.record("Expected reverted, got \(harness.recovery.state)")
            return
        }
        #expect(harness.fake.restorePermanentCount == 1)
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(restored?.level == .verified)
        #expect(harness.recovery.currentJournal()?.state == .reverted)
    }

    // MARK: Failures before or during apply

    @Test("Apply throws: the trial fails and the previous mode stays active")
    func applyThrows() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.applyError = DisplayHardwareError.coreGraphics(operation: "CGConfigureDisplayWithDisplayMode", code: 1001)
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: target)

        guard case .finished(.failed(let message, _)) = state else {
            Issue.record("Expected failed, got \(state)")
            return
        }
        #expect(message.contains("illegal argument"))
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(harness.recovery.currentJournal()?.state == .reverted)
        #expect(harness.historyKinds().first == .applyFailed)
        #expect(harness.services.verifications.records().isEmpty)
    }

    @Test("A driver that ignores the request fails verification and is reverted")
    func ignoredApply() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.ignoresApply = true
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: target)

        guard case .finished(.failed(let message, let restored)) = state else {
            Issue.record("Expected failed, got \(state)")
            return
        }
        #expect(message.contains("did not switch"))
        #expect(restored == nil, "the previous mode never left, so nothing needed restoring")
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(harness.recovery.currentJournal()?.state == .reverted)
        #expect(harness.historyKinds().first == .verificationFailed)
        #expect(harness.services.verifications.records().isEmpty)
    }

    @Test("Without AppKit confirmation the trial continues as partially verified and is not recorded as verified")
    func partialVerification() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.reportsScreens = false
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: target)
        let session = try #require(state.session, "state was \(state)")
        #expect(session.verification.level == .partial)
        #expect(session.verification.screenScale.provenance == .unavailable)
        #expect(harness.services.verifications.records().isEmpty)
        await harness.recovery.revert()
    }

    @Test("A refresh-rate drop is refused unless accepted, and nothing is applied")
    func refreshReductionRefused() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: asus.mode(82))

        guard case .finished(.failed(let message, nil)) = state else {
            Issue.record("Expected failed, got \(state)")
            return
        }
        #expect(message.contains("Drops from 120 Hz to 60 Hz"))
        #expect(harness.fake.applyCalls.isEmpty)
        #expect(harness.launcher.launches.isEmpty)
        #expect(harness.recovery.currentJournal() == nil)
        #expect(harness.services.backups.backup(for: display.key) == nil)
    }

    @Test("A refresh-rate drop proceeds once accepted")
    func refreshReductionAccepted() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: asus.mode(82), acceptRefreshReduction: true)
        #expect(state.session?.target.modeID == 82)
        #expect(harness.fake.currentModeID(on: 3) == 82)
        await harness.recovery.revert()
        #expect(harness.fake.currentModeID(on: 3) == 119)
    }

    @Test("An invalid target is refused without touching anything")
    func invalidTarget() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let display = try #require(harness.display())
        for bad in [previous, asus.mode(232), makeMode(999, 2752, 1152, 5504, 2304, 120, RawFlags.native)] {
            let state = await harness.recovery.beginTrial(on: display, to: bad)
            guard case .finished(.failed) = state else {
                Issue.record("Expected failed for \(bad.summary), got \(state)")
                continue
            }
        }
        #expect(harness.fake.applyCalls.isEmpty)
        #expect(harness.recovery.currentJournal() == nil)
    }

    @Test("Unwritable support directory: the trial fails and nothing is applied")
    func unwritableSupportDirectory() async throws {
        let harness = try ServicesHarness(unwritableRoot: true)
        defer { harness.cleanup() }
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: target)

        guard case .finished(.failed(let message, nil)) = state else {
            Issue.record("Expected failed, got \(state)")
            return
        }
        #expect(message.contains("could not be backed up"))
        #expect(harness.fake.applyCalls.isEmpty)
        #expect(harness.launcher.launches.isEmpty)
        #expect(harness.fake.currentModeID(on: 3) == 119)
    }

    @Test("Unwritable journal: the trial fails before the guard starts or anything is applied")
    func unwritableJournal() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        // A non-empty directory where the journal file should be makes the atomic write fail.
        try FileManager.default.createDirectory(
            at: harness.paths.trialJournalFile.appendingPathComponent("occupied"), withIntermediateDirectories: true)
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: target)

        guard case .finished(.failed(let message, nil)) = state else {
            Issue.record("Expected failed, got \(state)")
            return
        }
        #expect(message.contains("recovery journal could not be written"))
        #expect(harness.fake.applyCalls.isEmpty)
        #expect(harness.launcher.launches.isEmpty)
    }

    @Test("A display without a readable current mode is never changed")
    func noCurrentMode() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.setCurrentMode(nil, on: 3)
        let display = try #require(harness.display())
        let state = await harness.recovery.beginTrial(on: display, to: target)
        guard case .finished(.failed(let message, nil)) = state else {
            Issue.record("Expected failed, got \(state)")
            return
        }
        #expect(message.contains("could not be read"))
        #expect(harness.fake.applyCalls.isEmpty)
    }

    // MARK: Events during a trial

    @Test("Sleep before confirmation reverts the trial")
    func sleepReverts() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        await harness.recovery.handle(.systemWillSleep)

        guard case .finished(.reverted(_, let reason, _)) = harness.recovery.state else {
            Issue.record("Expected reverted, got \(harness.recovery.state)")
            return
        }
        #expect(reason.contains("sleep"))
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(harness.recovery.currentJournal()?.state == .reverted)
        #expect(harness.historyKinds().first == .autoReverted)
    }

    @Test("App termination event reverts the trial")
    func terminationReverts() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        await harness.recovery.handle(.appTerminating)
        guard case .finished(.reverted) = harness.recovery.state else {
            Issue.record("Expected reverted, got \(harness.recovery.state)")
            return
        }
        #expect(harness.fake.currentModeID(on: 3) == 119)
    }

    @Test("Disconnecting the display abandons the trial without applying anything")
    func displayRemoved() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let session = try await startTrial(harness)
        harness.fake.disconnect(3)
        await harness.recovery.handle(.targetDisplayRemoved)

        guard case .finished(.abandoned(let abandoned, let reason)) = harness.recovery.state else {
            Issue.record("Expected abandoned, got \(harness.recovery.state)")
            return
        }
        #expect(abandoned == session)
        #expect(reason.contains("disconnected"))
        #expect(harness.fake.applyCalls.count == 1)
        #expect(harness.recovery.currentJournal()?.state == .abandoned)
        #expect(harness.historyKinds().first == .abandoned)
    }

    @Test("An external mode change supersedes the trial and leaves the display alone")
    func externalChange() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        harness.fake.setCurrentMode(120, on: 3)
        await harness.recovery.handle(.targetDisplayChangedExternally)

        guard case .finished(.superseded) = harness.recovery.state else {
            Issue.record("Expected superseded, got \(harness.recovery.state)")
            return
        }
        #expect(harness.fake.currentModeID(on: 3) == 120)
        #expect(harness.fake.applyCalls.count == 1)
        #expect(harness.recovery.currentJournal()?.state == .superseded)
        #expect(harness.historyKinds().first == .superseded)
    }

    @Test("Events outside a trial are ignored")
    func eventsWhenIdle() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        await harness.recovery.handle(.systemWillSleep)
        await harness.recovery.keep()
        await harness.recovery.revert()
        #expect(harness.recovery.state == .idle)
        #expect(harness.fake.applyCalls.isEmpty)
    }

    @Test("prepareForTermination records that macOS reverts the app-only change")
    func prepareForTermination() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        _ = try await startTrial(harness)
        harness.recovery.prepareForTermination()
        #expect(harness.recovery.currentJournal()?.state == .revertedBySystem)
        #expect(harness.historyKinds().first == .autoReverted)
        #expect(harness.fake.applyCalls.count == 1)
    }

    // MARK: Launch recovery

    private let deadPID: Int32 = Int32.max - 1

    private func leftoverJournal(
        _ harness: ServicesHarness, state: TrialJournal.State = .pending, pid: Int32? = nil
    ) throws -> TrialJournal {
        let journal = TrialJournal(
            trialID: UUID(), state: state, appPID: pid ?? deadPID, displayKey: asus.key, displayID: 3,
            displayName: "VG34WQML5A", previous: previous, target: target,
            startedAt: Fixtures.fixedDate, deadline: Fixtures.fixedDate.addingTimeInterval(15),
            updatedAt: Fixtures.fixedDate, note: "Awaiting confirmation")
        try harness.writeJournal(journal)
        return journal
    }

    @Test("Launch: no journal means nothing to report")
    func launchNoJournal() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        #expect(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()) == nil)
    }

    @Test("Launch: macOS already restored the previous mode after a crash")
    func launchPreviousActive() async throws {
        #expect(!isProcessAlive(deadPID))
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let journal = try leftoverJournal(harness)
        let report = try #require(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()))
        #expect(report.assessment == .previousModeActive)
        #expect(report.journal.trialID == journal.trialID)
        #expect(report.journal.state == .revertedBySystem)
        #expect(report.message.contains("undone by macOS"))
        #expect(harness.recovery.currentJournal()?.state == .revertedBySystem)
        #expect(harness.historyKinds() == [.recovered])
        #expect(harness.fake.applyCalls.isEmpty)
    }

    @Test("Launch: the unconfirmed mode is still active and is restored permanently")
    func launchTrialStillActive() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.setCurrentMode(80, on: 3)
        _ = try leftoverJournal(harness)
        let report = try #require(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()))
        #expect(report.assessment == .trialModeStillActive)
        #expect(report.journal.state == .reverted)
        #expect(report.message.contains("ScaleKit restored 3440 × 1440 @ 120 Hz"))
        #expect(harness.fake.applyCalls == [.init(modeID: 119, displayID: 3, scope: .permanent)])
        #expect(harness.fake.currentModeID(on: 3) == 119)
        #expect(harness.recovery.currentJournal()?.state == .reverted)
        #expect(harness.historyKinds() == [.recovered])
    }

    @Test("Launch: a still-active trial that cannot be undone is reported honestly")
    func launchTrialCannotBeUndone() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.applyError = DisplayHardwareError.coreGraphics(operation: "CGCompleteDisplayConfiguration", code: 1000)
        // The fallback restores the saved configuration, which here is still the trial mode.
        harness.fake.connect(MonitorFixture(
            displayID: asus.displayID, vendorID: asus.vendorID, productID: asus.productID,
            serialNumber: asus.serialNumber, uuid: asus.uuid, name: asus.name, isMain: true,
            originX: 0, originY: 0, physicalSize: asus.physicalSize, modes: asus.modes, currentModeID: 80))
        _ = try leftoverJournal(harness)
        let report = try #require(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()))
        #expect(report.assessment == .trialModeStillActive)
        #expect(report.message.contains("could not be undone automatically"))
        #expect(harness.fake.restorePermanentCount == 1)
    }

    @Test("Launch: some other mode is active, so the display is left alone")
    func launchOtherMode() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.setCurrentMode(120, on: 3)
        _ = try leftoverJournal(harness)
        let report = try #require(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()))
        #expect(report.assessment == .otherModeActive)
        #expect(report.journal.state == .superseded)
        #expect(harness.fake.applyCalls.isEmpty)
        #expect(harness.fake.currentModeID(on: 3) == 120)
    }

    @Test("Launch: the display is not connected, so the journal is kept as abandoned")
    func launchDisplayMissing() async throws {
        let harness = try ServicesHarness(monitors: [Fixtures.msi])
        defer { harness.cleanup() }
        _ = try leftoverJournal(harness)
        let report = try #require(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()))
        #expect(report.assessment == .displayMissing)
        #expect(report.journal.state == .abandoned)
        #expect(harness.recovery.currentJournal()?.state == .abandoned)
        #expect(harness.fake.applyCalls.isEmpty)

        // When the display returns with the trial mode still active, the next launch restores it.
        harness.fake.connect(MonitorFixture(
            displayID: asus.displayID, vendorID: asus.vendorID, productID: asus.productID,
            serialNumber: asus.serialNumber, uuid: asus.uuid, name: asus.name, isMain: true,
            originX: 0, originY: 0, physicalSize: asus.physicalSize, modes: asus.modes, currentModeID: 80))
        let second = try #require(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()))
        #expect(second.assessment == .trialModeStillActive)
        #expect(harness.fake.currentModeID(on: 3) == 119)
    }

    @Test("Launch: a trial owned by another running ScaleKit is left alone")
    func launchOwnedByRunningInstance() async throws {
        let parent = getppid()
        try #require(parent != getpid() && isProcessAlive(parent))
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.setCurrentMode(80, on: 3)
        _ = try leftoverJournal(harness, pid: parent)
        #expect(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()) == nil)
        #expect(harness.recovery.currentJournal()?.state == .pending)
        #expect(harness.fake.applyCalls.isEmpty)
    }

    @Test("Launch: resolved journals are ignored", arguments: [TrialJournal.State.kept, .reverted, .superseded])
    func launchResolved(state: TrialJournal.State) async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.fake.setCurrentMode(80, on: 3)
        _ = try leftoverJournal(harness, state: state)
        #expect(await harness.recovery.recoverAfterLaunch(displays: harness.services.discovery.discover()) == nil)
        #expect(harness.fake.applyCalls.isEmpty)
    }
}
