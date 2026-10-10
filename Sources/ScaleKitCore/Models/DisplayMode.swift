import Foundation

/// Display mode flags reported by `CGDisplayModeGetIOFlags`.
///
/// Values are copied from `IOKit/graphics/IOGraphicsTypes.h` (macOS 27.0 SDK).
public struct DisplayModeFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let valid = DisplayModeFlags(rawValue: 0x0000_0001)
    public static let safe = DisplayModeFlags(rawValue: 0x0000_0002)
    public static let `default` = DisplayModeFlags(rawValue: 0x0000_0004)
    public static let alwaysShow = DisplayModeFlags(rawValue: 0x0000_0008)
    public static let notResize = DisplayModeFlags(rawValue: 0x0000_0010)
    public static let requiresPan = DisplayModeFlags(rawValue: 0x0000_0020)
    public static let interlaced = DisplayModeFlags(rawValue: 0x0000_0040)
    public static let neverShow = DisplayModeFlags(rawValue: 0x0000_0080)
    public static let simulscan = DisplayModeFlags(rawValue: 0x0000_0100)
    public static let notPreset = DisplayModeFlags(rawValue: 0x0000_0200)
    public static let builtIn = DisplayModeFlags(rawValue: 0x0000_0400)
    public static let stretched = DisplayModeFlags(rawValue: 0x0000_0800)
    public static let notGraphicsQuality = DisplayModeFlags(rawValue: 0x0000_1000)
    public static let television = DisplayModeFlags(rawValue: 0x0010_0000)
    public static let validForMirroring = DisplayModeFlags(rawValue: 0x0020_0000)
    public static let acceleratorBacked = DisplayModeFlags(rawValue: 0x0040_0000)
    public static let validForHiRes = DisplayModeFlags(rawValue: 0x0080_0000)
    public static let validForAirPlay = DisplayModeFlags(rawValue: 0x0100_0000)
    /// The mode uses the panel's native timing.
    public static let native = DisplayModeFlags(rawValue: 0x0200_0000)

    private static let named: [(DisplayModeFlags, String)] = [
        (.valid, "valid"), (.safe, "safe"), (.default, "default"), (.alwaysShow, "alwaysShow"),
        (.notResize, "notResize"), (.requiresPan, "requiresPan"), (.interlaced, "interlaced"),
        (.neverShow, "neverShow"), (.simulscan, "simulscan"), (.notPreset, "notPreset"),
        (.builtIn, "builtIn"), (.stretched, "stretched"), (.notGraphicsQuality, "notGraphicsQuality"),
        (.television, "television"), (.validForMirroring, "validForMirroring"),
        (.acceleratorBacked, "acceleratorBacked"), (.validForHiRes, "validForHiRes"),
        (.validForAirPlay, "validForAirPlay"), (.native, "native"),
    ]

    public var names: [String] {
        Self.named.filter { contains($0.0) }.map(\.1)
    }

    public var hexDescription: String { String(format: "0x%08X", rawValue) }
}

/// One display mode as reported by CoreGraphics.
public struct DisplayModeInfo: Codable, Hashable, Sendable, Identifiable {
    /// `CGDisplayModeGetIODisplayModeID`.
    public let modeID: Int32
    /// Logical size in points (`CGDisplayModeGetWidth/Height`).
    public let logical: PixelSize
    /// Backing store size in pixels (`CGDisplayModeGetPixelWidth/Height`).
    public let pixels: PixelSize
    /// Refresh rate in hertz. Zero means the system did not report one.
    public let refreshRate: Double
    public let flags: DisplayModeFlags
    public let isUsableForDesktopGUI: Bool

    public init(
        modeID: Int32, logical: PixelSize, pixels: PixelSize, refreshRate: Double,
        flags: DisplayModeFlags, isUsableForDesktopGUI: Bool
    ) {
        self.modeID = modeID
        self.logical = logical
        self.pixels = pixels
        self.refreshRate = refreshRate
        self.flags = flags
        self.isUsableForDesktopGUI = isUsableForDesktopGUI
    }

    public var id: Int32 { modeID }

    /// Backing pixels per point.
    public var scaleFactor: Double {
        logical.width > 0 ? Double(pixels.width) / Double(logical.width) : 1
    }

    public var isHiDPI: Bool { scaleFactor > 1.01 }
    public var hasNativeFlag: Bool { flags.contains(.native) }

    public var signature: ModeSignature {
        ModeSignature(logical: logical, pixels: pixels, refreshRate: refreshRate)
    }

    public var refreshLabel: String { RefreshRate.label(refreshRate) }

    /// For example "1720 × 720 HiDPI @ 120 Hz".
    public var summary: String {
        "\(logical)\(isHiDPI ? " HiDPI" : "") @ \(refreshLabel)"
    }
}

/// Identifies a mode by what it looks like rather than by its mode ID, which
/// can change when a display reconnects.
public struct ModeSignature: Codable, Hashable, Sendable, CustomStringConvertible {
    public let logical: PixelSize
    public let pixels: PixelSize
    /// Refresh rate in millihertz, rounded to absorb floating-point noise.
    public let refreshMilliHz: Int

    public init(logical: PixelSize, pixels: PixelSize, refreshRate: Double) {
        self.logical = logical
        self.pixels = pixels
        self.refreshMilliHz = Int((refreshRate * 1000).rounded())
    }

    public var refreshRate: Double { Double(refreshMilliHz) / 1000 }

    public var description: String {
        let hidpi = pixels.width > logical.width ? " HiDPI (\(pixels))" : ""
        return "\(logical)\(hidpi) @ \(RefreshRate.label(refreshRate))"
    }
}

public enum RefreshRate {
    public static func label(_ hertz: Double) -> String {
        guard hertz > 0 else { return "unknown refresh" }
        if abs(hertz - hertz.rounded()) < 0.005 { return "\(Int(hertz.rounded())) Hz" }
        return String(format: "%.2f Hz", hertz)
    }

    public static func isSame(_ a: Double, _ b: Double, tolerance: Double = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }
}

/// How a proposed refresh rate compares with the current one.
public enum RefreshComparison: Codable, Sendable, Equatable {
    case unchanged(Double)
    case increased(from: Double, to: Double)
    case decreased(from: Double, to: Double)
    case unknown

    public static func compare(from current: Double, to proposed: Double) -> RefreshComparison {
        guard current > 0, proposed > 0 else { return .unknown }
        if RefreshRate.isSame(current, proposed) { return .unchanged(proposed) }
        return proposed > current
            ? .increased(from: current, to: proposed)
            : .decreased(from: current, to: proposed)
    }

    public var isReduction: Bool {
        if case .decreased = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .unchanged(let hz): "Stays at \(RefreshRate.label(hz))"
        case .increased(let from, let to): "Rises from \(RefreshRate.label(from)) to \(RefreshRate.label(to))"
        case .decreased(let from, let to): "Drops from \(RefreshRate.label(from)) to \(RefreshRate.label(to))"
        case .unknown: "Refresh rate change cannot be determined"
        }
    }
}
