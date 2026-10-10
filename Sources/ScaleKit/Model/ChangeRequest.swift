import Foundation
import ScaleKitCore

/// A change the user asked for, waiting in the review sheet. Nothing has been
/// applied while a request exists.
struct ChangeRequest: Identifiable {
    enum Kind: Equatable {
        /// The clean mode mapped to a scaling profile.
        case profile(ScalingTarget)
        /// A closest alternative the user explicitly opted into for an unsupported profile.
        case alternative(desired: ScalingTarget, percent: Int)
        /// Back to the mode saved before ScaleKit's last change.
        case revert
        /// Back to the clean 100% mode.
        case reset
    }

    let id = UUID()
    let kind: Kind
    let displayID: UInt32
    let displayName: String
    let mode: DisplayModeInfo
    let plan: ChangePlan
    /// Seconds the user will have to keep the change.
    let timeout: Int

    var title: String {
        switch kind {
        case .profile(let target): "Switch to \(target)"
        case .alternative(_, let percent): "Use \(percent)% (\(mode.logical))"
        case .revert: "Revert to the previous mode"
        case .reset: "Reset to 100%"
        }
    }

    var isExplicitAlternative: Bool {
        if case .alternative = kind { return true }
        return false
    }

    /// (from, to) when the refresh rate would drop.
    var refreshDrop: (from: Double, to: Double)? {
        if case .decreased(let from, let to) = plan.refresh { return (from, to) }
        return nil
    }
}
