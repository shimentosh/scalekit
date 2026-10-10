import Foundation

/// Whether the active mode renders HiDPI, and how sure we are.
public struct HiDPIStatus: Codable, Sendable, Equatable {
    /// Nil when it cannot be determined.
    public var isActive: Bool?
    /// Backing pixels per point of the CoreGraphics mode.
    public var modeScale: Double?
    /// `NSScreen.backingScaleFactor`.
    public var screenScale: Double?
    public var confidence: Confidence
    public var explanation: String

    public init(isActive: Bool?, modeScale: Double?, screenScale: Double?, confidence: Confidence, explanation: String) {
        self.isActive = isActive
        self.modeScale = modeScale
        self.screenScale = screenScale
        self.confidence = confidence
        self.explanation = explanation
    }

    public var label: String {
        switch isActive {
        case true?: "HiDPI (\(Self.format(modeScale ?? screenScale ?? 2))×)"
        case false?: "Not HiDPI (1×)"
        case nil: "Unknown"
        }
    }

    static func format(_ scale: Double) -> String {
        scale == scale.rounded() ? "\(Int(scale))" : String(format: "%.2f", scale)
    }
}

/// Which HiDPI modes a display offers.
public struct HiDPIAvailability: Codable, Sendable, Equatable {
    public var hiDPIModeCount: Int
    /// HiDPI with a backing store exactly the panel size and the native flag.
    public var nativeHiDPIModes: [DisplayModeInfo]
    /// HiDPI with a backing store larger than the panel ("scaled" modes).
    public var supersampledHiDPIModes: [DisplayModeInfo]
    /// HiDPI modes with the panel's aspect ratio.
    public var aspectMatchedHiDPIModes: [DisplayModeInfo]
    public var summary: String

    public init(
        hiDPIModeCount: Int, nativeHiDPIModes: [DisplayModeInfo], supersampledHiDPIModes: [DisplayModeInfo],
        aspectMatchedHiDPIModes: [DisplayModeInfo], summary: String
    ) {
        self.hiDPIModeCount = hiDPIModeCount
        self.nativeHiDPIModes = nativeHiDPIModes
        self.supersampledHiDPIModes = supersampledHiDPIModes
        self.aspectMatchedHiDPIModes = aspectMatchedHiDPIModes
        self.summary = summary
    }
}

/// Pure HiDPI classification logic.
public enum HiDPIDetection {
    public static func renderingPath(for mode: DisplayModeInfo, native: PixelSize?) -> RenderingPath {
        guard let native, native.width > 0 else { return .unknown }
        if mode.pixels == native {
            return mode.isHiDPI ? .nativeHiDPI : .native1x
        }
        if mode.pixels.width >= native.width && mode.pixels.height >= native.height {
            return mode.isHiDPI ? .supersampledHiDPI : .unknown
        }
        return mode.isHiDPI ? .upscaledHiDPI : .upscaled1x
    }

    public static func availability(modes: [DisplayModeInfo], native: PixelSize?) -> HiDPIAvailability {
        let desktop = modes.filter(\.isUsableForDesktopGUI)
        let hiDPI = desktop.filter(\.isHiDPI)
        let nativeHiDPI = hiDPI.filter { renderingPath(for: $0, native: native) == .nativeHiDPI && $0.hasNativeFlag }
        let supersampled = hiDPI.filter { renderingPath(for: $0, native: native) == .supersampledHiDPI }
        let aspectMatched = native.map { native in hiDPI.filter { $0.logical.hasSameAspect(as: native) } } ?? []

        let summary: String
        if hiDPI.isEmpty {
            summary = "macOS offers no HiDPI modes for this display."
        } else {
            var parts = ["\(Set(hiDPI.map(\.logical)).count) HiDPI resolutions offered."]
            let nativeSizes = Set(nativeHiDPI.map(\.logical))
            if nativeSizes.isEmpty {
                parts.append("None renders at the panel's native resolution.")
            } else {
                parts.append("At native resolution: \(nativeSizes.map(\.description).sorted().joined(separator: ", ")).")
            }
            let shapedSupersampled = supersampled.filter { mode in
                native.map { mode.logical.hasSameAspect(as: $0) } ?? false
            }
            if shapedSupersampled.isEmpty {
                parts.append("No scaled (downsampled) HiDPI modes with the panel's aspect ratio.")
            }
            summary = parts.joined(separator: " ")
        }
        return HiDPIAvailability(
            hiDPIModeCount: hiDPI.count,
            nativeHiDPIModes: DisplayModeService.sorted(nativeHiDPI),
            supersampledHiDPIModes: DisplayModeService.sorted(supersampled),
            aspectMatchedHiDPIModes: DisplayModeService.sorted(aspectMatched),
            summary: summary
        )
    }

    /// Combines CoreGraphics and AppKit. Two independent sources that agree
    /// give high confidence.
    public static func status(currentMode: DisplayModeInfo?, screen: ScreenSnapshot?) -> HiDPIStatus {
        guard let currentMode else {
            if let screen {
                return HiDPIStatus(
                    isActive: screen.backingScaleFactor > 1.01, modeScale: nil, screenScale: screen.backingScaleFactor,
                    confidence: .low, explanation: "Only AppKit reported a scale; CoreGraphics returned no mode.")
            }
            return HiDPIStatus(
                isActive: nil, modeScale: nil, screenScale: nil, confidence: .none,
                explanation: "Neither CoreGraphics nor AppKit reported the display's scale.")
        }
        let modeScale = currentMode.scaleFactor
        guard let screen else {
            return HiDPIStatus(
                isActive: currentMode.isHiDPI, modeScale: modeScale, screenScale: nil, confidence: .medium,
                explanation: "From the CoreGraphics mode only; AppKit has no screen for this display.")
        }
        let screenScale = screen.backingScaleFactor
        if abs(modeScale - screenScale) < 0.01 {
            return HiDPIStatus(
                isActive: currentMode.isHiDPI, modeScale: modeScale, screenScale: screenScale, confidence: .high,
                explanation: "CoreGraphics (\(HiDPIStatus.format(modeScale))×) and AppKit (\(HiDPIStatus.format(screenScale))×) agree.")
        }
        return HiDPIStatus(
            isActive: currentMode.isHiDPI, modeScale: modeScale, screenScale: screenScale, confidence: .low,
            explanation: "CoreGraphics reports \(HiDPIStatus.format(modeScale))× but AppKit reports \(HiDPIStatus.format(screenScale))×. AppKit may not have caught up with a recent change.")
    }
}

/// Reports HiDPI status and availability for connected displays.
@MainActor
public final class HiDPIDetectionService {
    private let hardware: DisplayHardware
    private let modes: DisplayModeService

    public init(hardware: DisplayHardware, modes: DisplayModeService) {
        self.hardware = hardware
        self.modes = modes
    }

    public func status(for displayID: UInt32) -> HiDPIStatus {
        HiDPIDetection.status(
            currentMode: modes.currentMode(for: displayID),
            screen: hardware.screenSnapshots().first { $0.displayID == displayID })
    }

    public func availability(for displayID: UInt32) -> HiDPIAvailability {
        let all = modes.allModes(for: displayID)
        return HiDPIDetection.availability(
            modes: all, native: DisplayModeService.nativeResolution(from: all).value)
    }
}
