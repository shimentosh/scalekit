import Foundation
import Testing
@testable import ScaleKitCore

enum DecisionKind: Equatable, Sendable {
    case keep, revert, abandon, supersede, ignore
}

extension RollbackDecision {
    var kind: DecisionKind {
        switch self {
        case .keep: .keep
        case .revert: .revert
        case .abandon: .abandon
        case .supersede: .supersede
        case .ignore: .ignore
        }
    }

    var reason: String? {
        switch self {
        case .revert(let reason), .abandon(let reason), .supersede(let reason): reason
        case .keep, .ignore: nil
        }
    }
}

private let allEvents: [TrialEvent] = [
    .userKept, .userReverted, .timerExpired, .targetDisplayRemoved, .targetDisplayChangedExternally,
    .systemWillSleep, .appTerminating,
]

@Suite("Rollback policy")
struct RollbackPolicyTests {
    @Test("Every event is ignored outside the confirmation phase",
          arguments: allEvents, [TrialPhase.idle, .applying, .finished])
    func ignoredOutsideConfirmation(event: TrialEvent, phase: TrialPhase) {
        #expect(RollbackPolicy.decide(event, phase: phase) == .ignore)
    }

    @Test("Decisions while awaiting confirmation", arguments: zip(allEvents, [
        (DecisionKind.keep, ""),
        (.revert, "You chose Revert"),
        (.revert, "not confirmed in time"),
        (.abandon, "disconnected"),
        (.supersede, "outside ScaleKit"),
        (.revert, "sleep"),
        (.revert, "quit"),
    ]))
    func awaitingConfirmation(event: TrialEvent, expected: (DecisionKind, String)) {
        let decision = RollbackPolicy.decide(event, phase: .awaitingConfirmation)
        #expect(decision.kind == expected.0)
        if expected.0 == .keep {
            #expect(decision == .keep)
        } else {
            #expect(decision.reason?.contains(expected.1) == true, "\(decision)")
        }
    }

    @Test("Only an explicit Keep keeps a change")
    func onlyKeepKeeps() {
        let keeps = allEvents.filter { RollbackPolicy.decide($0, phase: .awaitingConfirmation) == .keep }
        #expect(keeps == [.userKept])
    }
}

@Suite("Launch recovery policy")
struct LaunchRecoveryPolicyTests {
    let previous = Fixtures.asus.mode(119)
    let target = Fixtures.asus.mode(80)
    let myPID: Int32 = 500
    let otherPID: Int32 = 600

    private func journal(_ state: TrialJournal.State = .pending, pid: Int32? = nil) -> TrialJournal {
        TrialJournal(
            trialID: UUID(), state: state, appPID: pid ?? otherPID, displayKey: Fixtures.asus.key,
            displayID: 3, displayName: "VG34WQML5A", previous: previous, target: target,
            startedAt: Fixtures.fixedDate, deadline: Fixtures.fixedDate.addingTimeInterval(15),
            updatedAt: Fixtures.fixedDate)
    }

    private func assess(
        _ journal: TrialJournal?, alive: Bool = false, current: DisplayModeInfo? = nil, connected: Bool = true
    ) -> LaunchAssessment {
        LaunchRecoveryPolicy.assess(
            journal: journal, currentPID: myPID, isProcessAlive: { _ in alive },
            currentMode: current, displayConnected: connected)
    }

    @Test("No journal: nothing to do")
    func noJournal() {
        #expect(assess(nil) == .nothingToDo)
    }

    @Test("Resolved journals need nothing", arguments: [
        TrialJournal.State.kept, .reverted, .revertedBySystem, .revertedByGuard, .superseded,
    ])
    func resolved(state: TrialJournal.State) {
        #expect(assess(journal(state), alive: false, current: target) == .nothingToDo)
    }

    @Test("A pending trial owned by another live process is left alone")
    func ownedByRunningInstance() {
        #expect(assess(journal(), alive: true, current: target) == .ownedByRunningInstance(pid: otherPID))
    }

    @Test("A pending trial with this process's PID is not treated as owned by another instance")
    func samePID() {
        #expect(assess(journal(pid: myPID), alive: true, current: target) == .trialModeStillActive)
    }

    @Test("An abandoned trial is re-checked even if its old PID is alive")
    func abandonedRechecked() {
        #expect(assess(journal(.abandoned), alive: true, current: previous) == .previousModeActive)
    }

    @Test("The display is missing")
    func displayMissing() {
        #expect(assess(journal(), current: nil, connected: false) == .displayMissing)
        #expect(assess(journal(.abandoned), current: nil, connected: false) == .displayMissing)
    }

    @Test("macOS already restored the previous mode")
    func previousModeActive() {
        #expect(assess(journal(), current: previous) == .previousModeActive)
    }

    @Test("The unconfirmed mode is still active")
    func trialModeStillActive() {
        #expect(assess(journal(), current: target) == .trialModeStillActive)
    }

    @Test("Some other mode is active, or none is reported")
    func otherModeActive() {
        #expect(assess(journal(), current: Fixtures.asus.mode(120)) == .otherModeActive)
        #expect(assess(journal(), current: nil, connected: true) == .otherModeActive)
    }

    @Test("Matching uses the mode's signature, not its ID")
    func matchesBySignature() {
        let renumbered = DisplayModeInfo(
            modeID: 9000, logical: target.logical, pixels: target.pixels, refreshRate: target.refreshRate,
            flags: target.flags, isUsableForDesktopGUI: true)
        #expect(assess(journal(), current: renumbered) == .trialModeStillActive)
    }

    @Test("Process liveness: this process is alive, an impossible PID is not")
    func liveness() {
        #expect(isProcessAlive(getpid()))
        #expect(!isProcessAlive(Int32.max - 1))
        #expect(!isProcessAlive(0))
        #expect(!isProcessAlive(-1))
    }
}
