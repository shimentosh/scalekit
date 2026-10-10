import Foundation
import ScaleKitCore

/// What the status area shows as the recommended supported profile.
struct RecommendationSummary: Equatable {
    var desired: ScalingTarget
    /// The standard profile the recommended mode belongs to, if any.
    var profile: ScalingTarget?
    var assessment: ModeAssessment?
    var status: SupportStatus?
    /// Native output, sharp text, the panel's aspect ratio and no refresh drop.
    var meetsAllCriteria: Bool
    /// For example "200% · 1720 × 720 HiDPI @ 120 Hz".
    var headline: String
    /// One or two sentences explaining the choice.
    var reason: String

    var isCurrent: Bool { assessment?.isCurrent ?? false }
}
