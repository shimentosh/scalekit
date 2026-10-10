import Foundation
import ScaleKitCore

/// A message shown at the top of the main window.
struct Banner: Identifiable, Equatable {
    enum Kind: Equatable {
        case success, info, warning, error
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var message: String
}

extension Banner {
    /// Describes how a trial ended. Success is only claimed when the mode was
    /// read back and AppKit agreed (`ApplyVerification.Level.verified`).
    static func outcome(
        _ outcome: RecoveryService.Outcome, describe: (DisplayModeInfo) -> String
    ) -> Banner {
        switch outcome {
        case .kept(let session, let verification):
            let mode = describe(session.target)
            switch verification.level {
            case .verified:
                return Banner(
                    kind: .success,
                    title: "Kept \(mode) on \(session.displayName)",
                    message: "Saved to your display preferences. ScaleKit read the mode back and AppKit confirmed the scale and size.")
            case .partial:
                return Banner(
                    kind: .warning,
                    title: "Kept \(mode) on \(session.displayName) — partially verified",
                    message: "macOS reports the requested mode, but AppKit did not confirm the scale and size. "
                        + verification.notes.joined(separator: " "))
            case .failed:
                return Banner(
                    kind: .error,
                    title: "The change could not be confirmed",
                    message: verification.notes.joined(separator: " "))
            }

        case .reverted(let session, let reason, let restored):
            let previous = describe(session.previous)
            switch restored?.level {
            case nil:
                return Banner(
                    kind: .info, title: "Reverted \(session.displayName)",
                    message: "\(reason) \(previous) was already active.")
            case .verified?:
                return Banner(
                    kind: .info, title: "Reverted \(session.displayName)",
                    message: "\(reason) \(previous) is active again (verified).")
            case .partial?:
                return Banner(
                    kind: .warning, title: "Reverted \(session.displayName) — partially verified",
                    message: "\(reason) macOS reports \(previous), but AppKit did not confirm the scale and size.")
            case .failed?:
                return Banner(
                    kind: .error, title: "Could not confirm the revert on \(session.displayName)",
                    message: "\(reason) ScaleKit could not confirm that \(previous) was restored. Check System Settings ▸ Displays.")
            }

        case .failed(let message, let restored):
            var text = message
            switch restored?.level {
            case .verified?: text += " The previous mode was restored (verified)."
            case .partial?: text += " The previous mode was restored (partially verified)."
            case .failed?: text += " ScaleKit could not confirm that the previous mode was restored. Check System Settings ▸ Displays."
            case nil: break
            }
            return Banner(kind: .error, title: "The change was not applied", message: text)

        case .abandoned(let session, let reason):
            return Banner(
                kind: .warning, title: "\(session.displayName) disconnected during the change",
                message: "\(reason) ScaleKit will check it again when it reconnects.")

        case .superseded(let session, let reason):
            return Banner(
                kind: .info, title: "\(session.displayName) was changed elsewhere",
                message: "\(reason) ScaleKit left the display as it is.")
        }
    }
}
