import Foundation

/// Maps desired interface sizes onto the modes macOS actually offers.
///
/// A profile is only ever mapped to a *clean* mode: native output, sharp
/// rendering and the panel's aspect ratio. Lower-resolution modes are listed
/// as alternatives with their trade-offs and are never selected automatically.
public enum ScalingProfileMapper {
    public static func evaluate(
        modes: [DisplayModeInfo],
        context: EvaluationContext,
        targets: [ScalingTarget] = ScalingTarget.standard
    ) -> [ProfileEvaluation] {
        targets.map { evaluate(target: $0, modes: modes, context: context) }
    }

    public static func evaluate(
        target: ScalingTarget, modes: [DisplayModeInfo], context: EvaluationContext
    ) -> ProfileEvaluation {
        let native = context.native
        let assessments = modes.map { RecommendationEngine.assess($0, desired: target, context: context) }
        let clean = assessments.filter {
            $0.isClean && abs($0.uiScale - target.factor) / target.factor <= RecommendationEngine.profileTolerance
        }
        let ideal = target.idealLogicalSize(native: native)

        if let chosen = preferred(clean, referenceRefresh: context.referenceRefresh) {
            let status: SupportStatus = chosen.isVerified ? .verified : .available
            var explanation = "\(chosen.mode.summary): \(chosen.renderingPath.label.lowercased()), native \(native) output."
            if chosen.refresh.isReduction {
                explanation += " Only available at \(chosen.mode.refreshLabel)."
            }
            if status == .available {
                explanation += " Offered by macOS; not yet applied and confirmed on this Mac."
            }
            return ProfileEvaluation(
                target: target, status: status, selection: chosen, alternatives: [],
                explanation: explanation, isCurrent: chosen.isCurrent)
        }

        let alternatives = closestAlternatives(assessments, native: native, referenceRefresh: context.referenceRefresh)
        var explanation = "macOS offers no mode that draws a \(target) interface (looks like ≈ \(ideal)) with sharp text at native \(native) output."
        if let first = alternatives.first {
            explanation += " Closest option: \(first.uiPercent)% · \(first.mode.summary)."
        }
        return ProfileEvaluation(
            target: target, status: .unsupported, selection: nil, alternatives: alternatives,
            explanation: explanation, isCurrent: false)
    }

    /// The UI size of the current mode, e.g. 1.0 for native.
    public static func currentUIScale(context: EvaluationContext) -> Double? {
        context.currentMode.map { RecommendationEngine.uiScale(of: $0, native: context.native) }
    }

    /// Exact reference refresh first, then the lowest refresh above it, then the
    /// highest below it.
    static func preferred(_ candidates: [ModeAssessment], referenceRefresh: Double) -> ModeAssessment? {
        candidates.min { a, b in
            RecommendationEngine.refreshPreference(a.mode.refreshRate, reference: referenceRefresh)
                < RecommendationEngine.refreshPreference(b.mode.refreshRate, reference: referenceRefresh)
        }
    }

    /// Up to three aspect-correct options, one per resolution, best score first.
    static func closestAlternatives(
        _ assessments: [ModeAssessment], native: PixelSize, referenceRefresh: Double
    ) -> [ModeAssessment] {
        let sameShape = assessments.filter(\.aspectMatchesNative)
        let grouped = Dictionary(grouping: sameShape) { "\($0.mode.logical)|\($0.mode.pixels)" }
        let representatives = grouped.values.compactMap { preferred($0, referenceRefresh: referenceRefresh) }
        return Array(representatives.sorted { a, b in
            if abs(a.score.total - b.score.total) > 0.001 { return a.score.total > b.score.total }
            return a.mode.modeID < b.mode.modeID
        }.prefix(3))
    }
}

/// Builds profile evaluations and recommendations for connected displays.
@MainActor
public final class ScalingProfileService {
    private let modes: DisplayModeService
    private let verifications: VerificationStore

    public init(modes: DisplayModeService, verifications: VerificationStore) {
        self.modes = modes
        self.verifications = verifications
    }

    public func context(for display: DisplayInfo, preferredRefresh: Double) -> EvaluationContext? {
        guard let native = display.nativeResolution.value else { return nil }
        let desktop = modes.desktopModes(for: display.id)
        return EvaluationContext(
            native: native,
            currentMode: display.currentMode,
            referenceRefresh: EvaluationContext.referenceRefresh(
                preferred: preferredRefresh, modes: desktop, current: display.currentMode),
            verifiedSignatures: verifications.verifiedSignatures(for: display.key))
    }

    public func evaluations(for display: DisplayInfo, preferredRefresh: Double) -> [ProfileEvaluation] {
        guard let context = context(for: display, preferredRefresh: preferredRefresh) else {
            return ScalingTarget.standard.map {
                ProfileEvaluation(
                    target: $0, status: .unknown, selection: nil, alternatives: [],
                    explanation: "The native resolution of this display could not be determined.", isCurrent: false)
            }
        }
        return ScalingProfileMapper.evaluate(modes: modes.desktopModes(for: display.id), context: context)
    }

    public func recommendation(
        for display: DisplayInfo, desired: ScalingTarget, preferredRefresh: Double,
        evaluations: [ProfileEvaluation]
    ) -> Recommendation? {
        guard let context = context(for: display, preferredRefresh: preferredRefresh) else { return nil }
        return RecommendationEngine.recommend(
            evaluations: evaluations, modes: modes.desktopModes(for: display.id),
            desired: desired, context: context)
    }

    public func assess(
        _ mode: DisplayModeInfo, on display: DisplayInfo, desired: ScalingTarget, preferredRefresh: Double
    ) -> ModeAssessment? {
        context(for: display, preferredRefresh: preferredRefresh).map {
            RecommendationEngine.assess(mode, desired: desired, context: $0)
        }
    }
}
