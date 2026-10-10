import Foundation

/// The user-facing status labels.
public enum SupportStatus: String, Codable, Sendable, CaseIterable {
    /// Applied on this Mac and confirmed by reading the active mode back, or currently active.
    case verified
    /// Offered by macOS for this display, but ScaleKit has not yet confirmed it here.
    case available
    /// Depends on private or undocumented behaviour. Not used by the stable app.
    case experimental
    /// Cannot be achieved with the modes macOS offers for this display.
    case unsupported
    /// Not enough information to decide.
    case unknown

    public var label: String { rawValue.capitalized }

    public var meaning: String {
        switch self {
        case .verified: "Applied on this Mac and confirmed by reading the active mode back."
        case .available: "Offered by macOS for this display, not yet confirmed on this Mac."
        case .experimental: "Relies on private or undocumented behaviour."
        case .unsupported: "macOS does not offer a suitable mode for this display."
        case .unknown: "There is not enough information to decide."
        }
    }
}

/// How sure ScaleKit is about a detection.
public enum Confidence: Int, Codable, Sendable, Comparable, CaseIterable {
    case none = 0, low, medium, high

    public var label: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
}
