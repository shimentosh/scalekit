import Foundation

/// Inputs shared by every mode assessment for one display.
public struct EvaluationContext: Sendable, Equatable {
    public var native: PixelSize
    public var currentMode: DisplayModeInfo?
    /// The refresh rate that changes should preserve.
    public var referenceRefresh: Double
    /// Modes that ScaleKit has applied and read back on this Mac.
    public var verifiedSignatures: Set<ModeSignature>

    public init(
        native: PixelSize, currentMode: DisplayModeInfo?, referenceRefresh: Double,
        verifiedSignatures: Set<ModeSignature>
    ) {
        self.native = native
        self.currentMode = currentMode
        self.referenceRefresh = referenceRefresh
        self.verifiedSignatures = verifiedSignatures
    }

    /// The preferred refresh rate if any desktop mode supports it, otherwise
    /// the current refresh rate.
    public static func referenceRefresh(
        preferred: Double, modes: [DisplayModeInfo], current: DisplayModeInfo?
    ) -> Double {
        if preferred > 0, modes.contains(where: { RefreshRate.isSame($0.refreshRate, preferred) }) {
            return preferred
        }
        return current?.refreshRate ?? preferred
    }
}

/// Transparent scoring of display modes.
///
/// Weights follow the priority order readability → native output → HiDPI →
/// refresh → aspect → stability → workspace. Native output plus sharp
/// rendering (35 points) outweighs perfect readability (25 points), so a
/// blurry mode can never outrank a sharp native one of the same shape and
/// refresh rate. Unverified modes earn fewer points than verified ones.
public enum RecommendationEngine {
    public static let readabilityWeight = 25.0
    public static let nativeOutputWeight = 20.0
    public static let sharpnessWeight = 15.0
    public static let refreshWeight = 15.0
    public static let aspectWeight = 10.0
    public static let stabilityWeight = 10.0
    public static let workspaceWeight = 5.0

    /// Relative difference allowed between a mode's UI size and a profile target.
    public static let profileTolerance = 0.03

    public static func uiScale(of mode: DisplayModeInfo, native: PixelSize) -> Double {
        mode.logical.width > 0 ? Double(native.width) / Double(mode.logical.width) : 0
    }

    public static func assess(
        _ mode: DisplayModeInfo, desired: ScalingTarget, context: EvaluationContext
    ) -> ModeAssessment {
        let native = context.native
        let scale = uiScale(of: mode, native: native)
        let path = HiDPIDetection.renderingPath(for: mode, native: native)
        let aspect = mode.logical.hasSameAspect(as: native)
        let isCurrent = context.currentMode?.signature == mode.signature
        let verified = context.verifiedSignatures.contains(mode.signature) || isCurrent
        let refresh = RefreshComparison.compare(from: context.referenceRefresh, to: mode.refreshRate)

        var components: [ScoreComponent] = []

        // 1. Readability: closeness to the desired size. Too small is penalised
        // more than too large because the user wants a bigger interface.
        let relative = (scale - desired.factor) / desired.factor
        let penalty = relative < 0 ? -relative * 3 : relative * 1.5
        components.append(ScoreComponent(
            name: "Readability",
            points: readabilityWeight * max(0, 1 - penalty),
            maxPoints: readabilityWeight,
            reason: "Interface is \(Int((scale * 100).rounded()))% (desired \(desired))"))

        // 2. Native output preservation.
        components.append(ScoreComponent(
            name: "Native output",
            points: mode.hasNativeFlag ? nativeOutputWeight : 0,
            maxPoints: nativeOutputWeight,
            reason: mode.hasNativeFlag
                ? "Uses the panel's native timing (kDisplayModeNativeFlag)"
                : "Not flagged as native output; the image is likely rescaled"))

        // 3. Sharpness / HiDPI, discounted until verified on this Mac.
        let sharpness: (Double, String) = switch path {
        case .nativeHiDPI:
            verified ? (15, "HiDPI at native resolution, verified on this Mac")
                : (10, "HiDPI at native resolution, not yet verified on this Mac")
        case .supersampledHiDPI:
            verified ? (13, "HiDPI downsampled to native, verified on this Mac")
                : (8, "HiDPI downsampled to native, not yet verified on this Mac")
        case .native1x: (8, "1:1 native pixels: sharp, but text is not HiDPI")
        case .upscaledHiDPI: (3, "HiDPI backing smaller than the panel, scaled up")
        case .upscaled1x: (0, "Rendered below panel resolution and scaled up: soft text")
        case .unknown: (0, "Rendering path unknown")
        }
        components.append(ScoreComponent(
            name: "Sharpness", points: sharpness.0, maxPoints: sharpnessWeight, reason: sharpness.1))

        // 4. Refresh-rate preservation.
        let refreshPoints: Double = switch refresh {
        case .unchanged, .increased: refreshWeight
        case .decreased(let from, let to): refreshWeight * to / from
        case .unknown: refreshWeight / 2
        }
        components.append(ScoreComponent(
            name: "Refresh rate", points: refreshPoints, maxPoints: refreshWeight,
            reason: "\(mode.refreshLabel) vs reference \(RefreshRate.label(context.referenceRefresh))"))

        // 5. Aspect-ratio preservation.
        components.append(ScoreComponent(
            name: "Aspect ratio",
            points: aspect ? aspectWeight : 0,
            maxPoints: aspectWeight,
            reason: aspect
                ? "\(mode.logical.aspectLabel), same as the panel"
                : "\(mode.logical.aspectLabel) on a \(native.aspectLabel) panel"))

        // 6. Compatibility and stability.
        var stability = 0.0
        if mode.isUsableForDesktopGUI { stability += 4 }
        if mode.flags.isSuperset(of: [.valid, .safe]) { stability += 3 }
        if !mode.flags.contains(.interlaced) && !mode.flags.contains(.stretched) { stability += 1 }
        if verified { stability += 2 }
        components.append(ScoreComponent(
            name: "Stability", points: stability, maxPoints: stabilityWeight,
            reason: verified ? "Desktop-usable, driver-validated, confirmed on this Mac"
                : "Desktop-usable and driver-validated; not yet confirmed on this Mac"))

        // 7. Workspace.
        let workspace = min(1, Double(mode.logical.area) / Double(max(1, native.area)))
        components.append(ScoreComponent(
            name: "Workspace", points: workspaceWeight * workspace, maxPoints: workspaceWeight,
            reason: "\(mode.logical) points (\(Int((workspace * 100).rounded()))% of native area)"))

        return ModeAssessment(
            mode: mode,
            uiScale: scale,
            renderingPath: path,
            outputIsNative: mode.hasNativeFlag,
            physicalOutput: physicalOutput(for: mode, native: native),
            aspectMatchesNative: aspect,
            refresh: refresh,
            isVerified: verified,
            isCurrent: isCurrent,
            tradeOffs: tradeOffs(for: mode, path: path, aspect: aspect, refresh: refresh, native: native),
            score: ModeScore(components: components)
        )
    }

    /// Highest score first. Ties go to clean modes, then to the refresh rate
    /// closest to the reference (exact, then nearest above, then nearest below),
    /// then to the mode ID. Without the refresh tie-break a 250 Hz mode would
    /// win over the user's preferred 120 Hz, because both earn full refresh points.
    public static func rank(
        _ modes: [DisplayModeInfo], desired: ScalingTarget, context: EvaluationContext
    ) -> [ModeAssessment] {
        modes.map { assess($0, desired: desired, context: context) }.sorted { a, b in
            if abs(a.score.total - b.score.total) > 0.001 { return a.score.total > b.score.total }
            if a.isClean != b.isClean { return a.isClean }
            let refreshA = refreshPreference(a.mode.refreshRate, reference: context.referenceRefresh)
            let refreshB = refreshPreference(b.mode.refreshRate, reference: context.referenceRefresh)
            if refreshA != refreshB { return refreshA < refreshB }
            return a.mode.modeID < b.mode.modeID
        }
    }

    /// Sort key: exact reference refresh first, then the nearest higher rate,
    /// then the nearest lower rate.
    public static func refreshPreference(_ refresh: Double, reference: Double) -> RefreshPreference {
        if RefreshRate.isSame(refresh, reference) { return RefreshPreference(tier: 0, distance: 0) }
        if refresh > reference { return RefreshPreference(tier: 1, distance: refresh - reference) }
        return RefreshPreference(tier: 2, distance: reference - refresh)
    }

    public struct RefreshPreference: Comparable, Sendable {
        public var tier: Int
        public var distance: Double

        public static func < (lhs: RefreshPreference, rhs: RefreshPreference) -> Bool {
            (lhs.tier, lhs.distance) < (rhs.tier, rhs.distance)
        }
    }

    public static func recommend(
        evaluations: [ProfileEvaluation],
        modes: [DisplayModeInfo],
        desired: ScalingTarget,
        context: EvaluationContext
    ) -> Recommendation {
        let candidates = modes.filter { $0.logical.hasSameAspect(as: context.native) }
        let ranked = rank(candidates.isEmpty ? modes : candidates, desired: desired, context: context)
        guard let best = ranked.first else {
            return Recommendation(
                desired: desired, assessment: nil, profile: nil, meetsAllCriteria: false,
                headline: "No usable display modes were reported.", reasons: [])
        }
        let profile = evaluations.first { $0.selection?.mode.signature == best.mode.signature }?.target
        let meetsAll = best.isClean && !best.refresh.isReduction
        let label = profile.map { "\($0) · " } ?? "\(best.uiPercent)% · "
        let headline = meetsAll
            ? "\(label)\(best.mode.summary) keeps native output, sharp text, \(best.mode.refreshLabel) and the panel's aspect ratio."
            : "No mode meets every criterion for \(desired). Best available: \(label)\(best.mode.summary)."
        let reasons = best.score.components
            .sorted { ($0.maxPoints - $0.points) < ($1.maxPoints - $1.points) }
            .map { "\($0.name): \($0.reason) (\(format($0.points))/\(format($0.maxPoints)))" }
        return Recommendation(
            desired: desired, assessment: best, profile: profile, meetsAllCriteria: meetsAll,
            headline: headline, reasons: reasons)
    }

    // MARK: - Helpers

    public static func physicalOutput(for mode: DisplayModeInfo, native: PixelSize) -> Fact<PixelSize> {
        if mode.hasNativeFlag {
            return .inferred(native, reason: "Mode carries kDisplayModeNativeFlag")
        }
        return .unavailable("Not flagged native; macOS does not report the output timing for this mode")
    }

    static func tradeOffs(
        for mode: DisplayModeInfo, path: RenderingPath, aspect: Bool,
        refresh: RefreshComparison, native: PixelSize
    ) -> [String] {
        var notes: [String] = []
        switch path {
        case .upscaled1x:
            notes.append("Rendered at \(mode.pixels) and scaled up to \(native): text and edges look softer.")
        case .upscaledHiDPI:
            notes.append("HiDPI backing (\(mode.pixels)) is smaller than the panel and is scaled up: softer than native.")
        case .supersampledHiDPI:
            notes.append("Rendered at \(mode.pixels) and downsampled to \(native): sharp, with slightly higher GPU load.")
        case .native1x, .nativeHiDPI, .unknown:
            break
        }
        if !mode.hasNativeFlag {
            notes.append("macOS does not mark this mode as native output, so the physical signal resolution is unknown.")
        }
        if !aspect {
            notes.append("\(mode.logical.aspectLabel) shape on a \(native.aspectLabel) panel: black bars or stretching.")
        }
        if case .decreased(let from, let to) = refresh {
            notes.append("Refresh rate drops from \(RefreshRate.label(from)) to \(RefreshRate.label(to)).")
        }
        let area = Double(mode.logical.area) / Double(max(1, native.area))
        if area < 0.5 {
            notes.append("Workspace is \(mode.logical) points, \(Int((area * 100).rounded()))% of the native desktop area.")
        }
        return notes
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
