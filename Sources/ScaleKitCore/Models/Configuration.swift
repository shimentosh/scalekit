import Foundation

/// How long a display change lasts (`CGConfigureOption`).
public enum ConfigurationScope: String, Codable, Sendable {
    /// Reverted by WindowServer when the process that made it exits, including crashes.
    case appOnly
    /// Lasts until logout.
    case session
    /// Saved to the user's display preferences.
    case permanent

    public var explanation: String {
        switch self {
        case .appOnly: "Until ScaleKit quits (macOS reverts it automatically)"
        case .session: "Until you log out"
        case .permanent: "Saved to your display preferences"
        }
    }
}

/// The mode a display was in at a point in time.
public struct DisplayStateRecord: Codable, Sendable, Equatable {
    public var displayKey: String
    public var displayID: UInt32
    public var displayName: String
    public var mode: DisplayModeInfo
    public var capturedAt: Date

    public init(displayKey: String, displayID: UInt32, displayName: String, mode: DisplayModeInfo, capturedAt: Date) {
        self.displayKey = displayKey
        self.displayID = displayID
        self.displayName = displayName
        self.mode = mode
        self.capturedAt = capturedAt
    }
}

/// One line in the configuration history.
public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case backupSaved, trialStarted, applyFailed, verificationFailed
        case kept, reverted, autoReverted, recovered, abandoned, superseded

        public var label: String {
            switch self {
            case .backupSaved: "Backup saved"
            case .trialStarted: "Trial started"
            case .applyFailed: "Apply failed"
            case .verificationFailed: "Verification failed"
            case .kept: "Kept"
            case .reverted: "Reverted"
            case .autoReverted: "Automatically reverted"
            case .recovered: "Recovered after restart"
            case .abandoned: "Abandoned (display disconnected)"
            case .superseded: "Superseded by another change"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var displayName: String
    public var displayKey: String
    public var from: ModeSignature?
    public var to: ModeSignature?
    public var detail: String

    public init(
        id: UUID = UUID(), date: Date, kind: Kind, displayName: String, displayKey: String,
        from: ModeSignature?, to: ModeSignature?, detail: String
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.displayName = displayName
        self.displayKey = displayKey
        self.from = from
        self.to = to
        self.detail = detail
    }
}

/// Proof that a mode was applied and read back on a specific Mac.
public struct VerificationRecord: Codable, Sendable, Equatable {
    public var displayKey: String
    public var displayName: String
    public var signature: ModeSignature
    public var verifiedAt: Date
    public var osVersion: String
    public var hardwareModel: String
    public var observedScale: Double?
    public var method: String

    public init(
        displayKey: String, displayName: String, signature: ModeSignature, verifiedAt: Date,
        osVersion: String, hardwareModel: String, observedScale: Double?, method: String
    ) {
        self.displayKey = displayKey
        self.displayName = displayName
        self.signature = signature
        self.verifiedAt = verifiedAt
        self.osVersion = osVersion
        self.hardwareModel = hardwareModel
        self.observedScale = observedScale
        self.method = method
    }
}

/// On-disk record of an unconfirmed display change, written before the change
/// is applied so that a crash, hang or restart can be recovered from.
public struct TrialJournal: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case pending, kept, reverted, revertedBySystem, revertedByGuard, abandoned, superseded
    }

    public var trialID: UUID
    public var state: State
    public var appPID: Int32
    public var displayKey: String
    public var displayID: UInt32
    public var displayName: String
    public var previous: DisplayModeInfo
    public var target: DisplayModeInfo
    public var startedAt: Date
    public var deadline: Date
    public var updatedAt: Date
    public var note: String?

    public init(
        trialID: UUID, state: State, appPID: Int32, displayKey: String, displayID: UInt32,
        displayName: String, previous: DisplayModeInfo, target: DisplayModeInfo,
        startedAt: Date, deadline: Date, updatedAt: Date, note: String? = nil
    ) {
        self.trialID = trialID
        self.state = state
        self.appPID = appPID
        self.displayKey = displayKey
        self.displayID = displayID
        self.displayName = displayName
        self.previous = previous
        self.target = target
        self.startedAt = startedAt
        self.deadline = deadline
        self.updatedAt = updatedAt
        self.note = note
    }
}
