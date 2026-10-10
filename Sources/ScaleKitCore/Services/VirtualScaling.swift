import Foundation

/// Sizes for HiDPI scaling through a virtual display (Experimental).
///
/// macOS only offers in-between HiDPI sizes on high-density panels. ScaleKit
/// can work around that by creating a virtual display with a single HiDPI
/// mode and mirroring the physical monitor to it: macOS renders the desktop
/// at twice the "looks like" size and scales that image to the panel. For
/// 125–175% on a 3440 × 1440 panel the render is larger than the panel, so
/// the image is downsampled and text stays sharp.
///
/// The virtual display uses a private CoreGraphics API (see the
/// ScaleKitVirtual module). This type is pure arithmetic and makes no system
/// calls.
public struct VirtualScalingPlan: Codable, Hashable, Sendable {
    public var target: ScalingTarget
    /// The physical panel's native resolution.
    public var native: PixelSize
    /// The desktop size in points ("looks like").
    public var points: PixelSize
    /// The virtual display's backing store: twice `points`.
    public var pixels: PixelSize
    public var refreshRate: Double

    /// Percentages that need a virtual display. 100% and 200% have clean
    /// native modes, which are always preferred.
    public static let supportedPercents = 105...195
    /// Largest backing width or height ScaleKit will ask for.
    public static let maxBackingDimension = 8192

    public init?(target: ScalingTarget, native: PixelSize, refreshRate: Double) {
        guard Self.supportedPercents.contains(target.percent),
              native.width > 0, native.height > 0, refreshRate > 0
        else { return nil }
        let width = Int((Double(native.width) / target.factor).rounded())
        let height = Int((Double(width) * Double(native.height) / Double(native.width)).rounded())
        guard width > 0, height > 0,
              width * 2 <= Self.maxBackingDimension, height * 2 <= Self.maxBackingDimension
        else { return nil }
        self.target = target
        self.native = native
        self.points = PixelSize(width: width, height: height)
        self.pixels = PixelSize(width: width * 2, height: height * 2)
        self.refreshRate = refreshRate
    }

    /// The interface scale actually produced (native width ÷ points width).
    public var effectiveScale: Double { Double(native.width) / Double(points.width) }

    /// Rendered pixels per panel pixel along the width. Above 1 the image is
    /// downsampled (sharp); below 1 it is upscaled (soft).
    public var sampling: Double { Double(pixels.width) / Double(native.width) }

    public var isDownsampled: Bool { sampling >= 1 }

    /// Pixels the GPU renders relative to the native 1× desktop (2.6 = 2.6× as many).
    public var renderLoad: Double { Double(pixels.area) / Double(max(1, native.area)) }

    /// A mode description of the virtual display for presentation and history.
    public var modeInfo: DisplayModeInfo {
        DisplayModeInfo(
            modeID: -1, logical: points, pixels: pixels, refreshRate: refreshRate,
            flags: [.valid, .safe], isUsableForDesktopGUI: true)
    }

    public var summary: String {
        "\(points) pt HiDPI · rendered at \(pixels) · \(RefreshRate.label(refreshRate))"
    }

    /// Plain-language trade-offs shown before the user tries it.
    public var tradeOffs: [String] {
        var notes = [
            "Uses a private macOS API (virtual display + mirroring). If a macOS update removes it, ScaleKit shows this size as unavailable.",
            "Works only while ScaleKit is running. Quitting ScaleKit, or a crash, returns the monitor to its normal mode.",
            String(format: "The GPU renders %.1f× the pixels of the native desktop.", renderLoad),
        ]
        if !isDownsampled {
            notes.append("The render is smaller than the panel and is scaled up, so text is softer than at 100% or 200%.")
        }
        notes.append("Some features can behave differently on a mirrored display: HDR, variable refresh rate and screen recording of the physical monitor.")
        return notes
    }
}

/// The virtual-display scaling the user kept, so it can be re-applied when
/// ScaleKit starts again.
public struct VirtualScalingPreference: Codable, Hashable, Sendable {
    public var displayKey: String
    public var displayName: String
    public var percent: Int
    public var savedAt: Date

    public init(displayKey: String, displayName: String, percent: Int, savedAt: Date) {
        self.displayKey = displayKey
        self.displayName = displayName
        self.percent = percent
        self.savedAt = savedAt
    }
}

/// What a virtual-scaling trial journal found at launch means.
public enum VirtualTrialLaunchPolicy {
    /// A pending journal whose process is gone: macOS already removed the
    /// virtual display when that process exited, so the monitor is back to
    /// normal and only the journal needs closing.
    public static func needsClosing(
        _ journal: TrialJournal?, currentPID: Int32, isProcessAlive: (Int32) -> Bool
    ) -> Bool {
        guard let journal, journal.state == .pending else { return false }
        return journal.appPID != currentPID && !isProcessAlive(journal.appPID)
    }
}

/// Keeps the desktop arrangement intact when a display changes size.
///
/// When the scaled monitor's desktop shrinks (3440 → 2752 points wide at
/// 125%), a monitor that sat against its right or bottom edge would be left
/// floating. macOS then rearranges displays on its own, which moves windows
/// and the Dock. This computes origins that keep every neighbour touching the
/// same edge, with its offset along that edge scaled proportionally.
public enum DisplayArrangement {
    public struct Placement: Equatable, Sendable {
        public var displayID: UInt32
        public var x: Int
        public var y: Int

        public init(displayID: UInt32, x: Int, y: Int) {
            self.displayID = displayID
            self.x = x
            self.y = y
        }
    }

    /// Origins for `others` after `resized` changes from its current size to
    /// `newSize`, keeping its own origin. Only displays whose origin changes
    /// are returned.
    public static func placements(
        resized: DisplayBounds, newSize: PixelSize, others: [(id: UInt32, bounds: DisplayBounds)]
    ) -> [Placement] {
        let dx = resized.width - Double(newSize.width)
        let dy = resized.height - Double(newSize.height)
        let sx = resized.width > 0 ? Double(newSize.width) / resized.width : 1
        let sy = resized.height > 0 ? Double(newSize.height) / resized.height : 1
        let edge = 1.0
        var result: [Placement] = []
        for other in others {
            let b = other.bounds
            var x = b.x
            var y = b.y
            let overlapsVertically = b.y < resized.y + resized.height && b.y + b.height > resized.y
            let overlapsHorizontally = b.x < resized.x + resized.width && b.x + b.width > resized.x
            if b.x >= resized.x + resized.width - edge {
                // Right neighbour: follow the new right edge.
                x = b.x - dx
                if overlapsVertically { y = resized.y + (b.y - resized.y) * sy }
            } else if b.y >= resized.y + resized.height - edge {
                // Neighbour below: follow the new bottom edge.
                y = b.y - dy
                if overlapsHorizontally { x = resized.x + (b.x - resized.x) * sx }
            } else if b.x + b.width <= resized.x + edge, overlapsVertically {
                // Left neighbour: keep the edge, scale the offset along it.
                y = resized.y + (b.y - resized.y) * sy
            } else if b.y + b.height <= resized.y + edge, overlapsHorizontally {
                // Neighbour above.
                x = resized.x + (b.x - resized.x) * sx
            }
            let placement = Placement(displayID: other.id, x: Int(x.rounded()), y: Int(y.rounded()))
            if placement.x != Int(b.x.rounded()) || placement.y != Int(b.y.rounded()) {
                result.append(placement)
            }
        }
        return result
    }
}
