import Foundation

/// A desired interface size, such as 150%. Not a promise that macOS offers it.
public struct ScalingTarget: Codable, Hashable, Sendable, Identifiable, Comparable, CustomStringConvertible {
    public let percent: Int

    public init(percent: Int) { self.percent = percent }

    public var id: Int { percent }
    public var factor: Double { Double(percent) / 100 }
    public var description: String { "\(percent)%" }

    public static let standard: [ScalingTarget] = [100, 125, 150, 175, 200].map(ScalingTarget.init(percent:))

    /// The "looks like" size this target would need on a panel of `native` pixels.
    public func idealLogicalSize(native: PixelSize) -> PixelSize {
        PixelSize(
            width: Int((Double(native.width) / factor).rounded()),
            height: Int((Double(native.height) / factor).rounded())
        )
    }

    public static func < (lhs: ScalingTarget, rhs: ScalingTarget) -> Bool { lhs.percent < rhs.percent }
}

/// How a mode's backing store relates to the panel's native pixels.
public enum RenderingPath: String, Codable, Sendable {
    /// One point is one panel pixel.
    case native1x
    /// 2× backing store exactly the size of the panel: HiDPI text, no resampling.
    case nativeHiDPI
    /// HiDPI backing store larger than the panel, downsampled to it.
    case supersampledHiDPI
    /// HiDPI backing store smaller than the panel, enlarged to fill it.
    case upscaledHiDPI
    /// 1× mode smaller than the panel, enlarged by the GPU or the monitor.
    case upscaled1x
    case unknown

    /// Text is drawn at or above panel resolution.
    public var isSharp: Bool {
        switch self {
        case .native1x, .nativeHiDPI, .supersampledHiDPI: true
        case .upscaledHiDPI, .upscaled1x, .unknown: false
        }
    }

    public var label: String {
        switch self {
        case .native1x: "1:1 native pixels"
        case .nativeHiDPI: "HiDPI at native resolution"
        case .supersampledHiDPI: "HiDPI, downsampled to native"
        case .upscaledHiDPI: "HiDPI, scaled up to fill the panel"
        case .upscaled1x: "Lower resolution, scaled up"
        case .unknown: "Unknown"
        }
    }
}

/// One line of the transparent scoring breakdown.
public struct ScoreComponent: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var points: Double
    public var maxPoints: Double
    public var reason: String

    public init(name: String, points: Double, maxPoints: Double, reason: String) {
        self.name = name
        self.points = points
        self.maxPoints = maxPoints
        self.reason = reason
    }

    public var id: String { name }
}

public struct ModeScore: Codable, Sendable, Equatable {
    public var components: [ScoreComponent]

    public init(components: [ScoreComponent]) { self.components = components }

    public var total: Double { components.reduce(0) { $0 + $1.points } }
    public var maxTotal: Double { components.reduce(0) { $0 + $1.maxPoints } }
}

/// A display mode evaluated against a desired interface size.
public struct ModeAssessment: Codable, Sendable, Equatable, Identifiable {
    public var mode: DisplayModeInfo
    /// Interface size relative to native, e.g. 2.0 for 200%.
    public var uiScale: Double
    public var renderingPath: RenderingPath
    /// The mode carries `kDisplayModeNativeFlag`.
    public var outputIsNative: Bool
    public var physicalOutput: Fact<PixelSize>
    public var aspectMatchesNative: Bool
    public var refresh: RefreshComparison
    public var isVerified: Bool
    public var isCurrent: Bool
    public var tradeOffs: [String]
    public var score: ModeScore

    public init(
        mode: DisplayModeInfo, uiScale: Double, renderingPath: RenderingPath, outputIsNative: Bool,
        physicalOutput: Fact<PixelSize>, aspectMatchesNative: Bool, refresh: RefreshComparison,
        isVerified: Bool, isCurrent: Bool, tradeOffs: [String], score: ModeScore
    ) {
        self.mode = mode
        self.uiScale = uiScale
        self.renderingPath = renderingPath
        self.outputIsNative = outputIsNative
        self.physicalOutput = physicalOutput
        self.aspectMatchesNative = aspectMatchesNative
        self.refresh = refresh
        self.isVerified = isVerified
        self.isCurrent = isCurrent
        self.tradeOffs = tradeOffs
        self.score = score
    }

    public var id: Int32 { mode.modeID }
    public var uiPercent: Int { Int((uiScale * 100).rounded()) }

    /// Native output, sharp rendering and the panel's own aspect ratio.
    public var isClean: Bool { outputIsNative && renderingPath.isSharp && aspectMatchesNative }

    /// Status of this specific mode.
    public var status: SupportStatus { isVerified || isCurrent ? .verified : .available }
}

/// The result of mapping one desired interface size onto the modes macOS offers.
public struct ProfileEvaluation: Codable, Sendable, Equatable, Identifiable {
    public var target: ScalingTarget
    public var status: SupportStatus
    /// The clean mode chosen for this target, if one exists.
    public var selection: ModeAssessment?
    /// Closest options when no clean mode exists. Never applied automatically.
    public var alternatives: [ModeAssessment]
    public var explanation: String
    public var isCurrent: Bool

    public init(
        target: ScalingTarget, status: SupportStatus, selection: ModeAssessment?,
        alternatives: [ModeAssessment], explanation: String, isCurrent: Bool
    ) {
        self.target = target
        self.status = status
        self.selection = selection
        self.alternatives = alternatives
        self.explanation = explanation
        self.isCurrent = isCurrent
    }

    public var id: Int { target.percent }
}

/// The recommendation engine's answer for a desired size.
public struct Recommendation: Codable, Sendable, Equatable {
    public var desired: ScalingTarget
    public var assessment: ModeAssessment?
    /// Set when the recommended mode is the clean mapping of a standard profile.
    public var profile: ScalingTarget?
    /// Native output, sharp text, native aspect and the reference refresh rate.
    public var meetsAllCriteria: Bool
    public var headline: String
    public var reasons: [String]

    public init(
        desired: ScalingTarget, assessment: ModeAssessment?, profile: ScalingTarget?,
        meetsAllCriteria: Bool, headline: String, reasons: [String]
    ) {
        self.desired = desired
        self.assessment = assessment
        self.profile = profile
        self.meetsAllCriteria = meetsAllCriteria
        self.headline = headline
        self.reasons = reasons
    }
}
