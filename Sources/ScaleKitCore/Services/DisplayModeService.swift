import Foundation

/// Reads, filters and validates display modes.
@MainActor
public final class DisplayModeService {
    private let hardware: DisplayHardware

    public init(hardware: DisplayHardware) {
        self.hardware = hardware
    }

    public func currentMode(for displayID: UInt32) -> DisplayModeInfo? {
        hardware.currentMode(for: displayID)
    }

    /// Every mode macOS reports, including HiDPI duplicates and modes that are
    /// not usable for the desktop.
    public func allModes(for displayID: UInt32) -> [DisplayModeInfo] {
        Self.sorted(hardware.allModes(for: displayID, includeLowResolutionDuplicates: true))
    }

    /// Desktop-usable modes with exact duplicates removed.
    public func desktopModes(for displayID: UInt32) -> [DisplayModeInfo] {
        Self.desktopModes(from: allModes(for: displayID))
    }

    public func mode(withID modeID: Int32, for displayID: UInt32) -> DisplayModeInfo? {
        allModes(for: displayID).first { $0.modeID == modeID }
    }

    /// Finds the mode matching a saved signature. Mode IDs can change across
    /// reconnects, so restore operations match on what the mode looks like.
    public func mode(matching signature: ModeSignature, for displayID: UInt32) -> DisplayModeInfo? {
        desktopModes(for: displayID).first { $0.signature == signature }
    }

    // MARK: - Pure helpers

    public nonisolated static func desktopModes(from modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
        deduplicated(modes.filter { $0.isUsableForDesktopGUI && $0.flags.contains(.valid) })
    }

    /// Keeps one mode per signature, preferring the driver's default-flagged entry
    /// and then the lowest mode ID.
    public nonisolated static func deduplicated(_ modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
        var best: [ModeSignature: DisplayModeInfo] = [:]
        for mode in modes {
            guard let existing = best[mode.signature] else {
                best[mode.signature] = mode
                continue
            }
            let preferNew = (mode.flags.contains(.default) && !existing.flags.contains(.default))
                || (mode.flags.contains(.default) == existing.flags.contains(.default) && mode.modeID < existing.modeID)
            if preferNew { best[mode.signature] = mode }
        }
        return sorted(Array(best.values))
    }

    /// Largest logical size first, then 1× before HiDPI, then highest refresh rate.
    public nonisolated static func sorted(_ modes: [DisplayModeInfo]) -> [DisplayModeInfo] {
        modes.sorted { a, b in
            if a.logical.area != b.logical.area { return a.logical.area > b.logical.area }
            if a.logical.width != b.logical.width { return a.logical.width > b.logical.width }
            if a.pixels.area != b.pixels.area { return a.pixels.area < b.pixels.area }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.modeID < b.modeID
        }
    }

    /// The panel resolution: the largest 1× mode the driver flags as native.
    /// HiDPI modes are only used when no 1× mode is flagged, because a
    /// supersampled mode's backing store can exceed the panel. Falls back to
    /// the largest 1× mode (inferred).
    public nonisolated static func nativeResolution(from modes: [DisplayModeInfo]) -> Fact<PixelSize> {
        let flagged = modes.filter(\.hasNativeFlag)
        let native = flagged.filter { !$0.isHiDPI }.max { $0.pixels.area < $1.pixels.area }
            ?? flagged.max { $0.pixels.area < $1.pixels.area }
        if let native {
            return .measured(native.pixels, source: "Largest mode flagged kDisplayModeNativeFlag by the display driver")
        }
        let largest1x = modes.filter { !$0.isHiDPI }.max { $0.pixels.area < $1.pixels.area }
        if let largest1x {
            return .inferred(largest1x.pixels, reason: "No mode carries the native flag; using the largest 1× mode")
        }
        return .unavailable("macOS reported no display modes")
    }
}

/// Result of checking a proposed mode before it is applied.
public struct ModeValidation: Codable, Sendable, Equatable {
    /// Problems that block the change.
    public var errors: [String]
    /// Trade-offs the user must see before confirming.
    public var warnings: [String]
    /// The change lowers the refresh rate and needs explicit acknowledgement.
    public var requiresRefreshConfirmation: Bool

    public init(errors: [String] = [], warnings: [String] = [], requiresRefreshConfirmation: Bool = false) {
        self.errors = errors
        self.warnings = warnings
        self.requiresRefreshConfirmation = requiresRefreshConfirmation
    }

    public var isValid: Bool { errors.isEmpty }
}

public enum ModeValidator {
    public static func validate(
        _ target: DisplayModeInfo,
        available: [DisplayModeInfo],
        current: DisplayModeInfo?,
        native: PixelSize?
    ) -> ModeValidation {
        var result = ModeValidation()

        let offered = available.contains { $0.modeID == target.modeID && $0.signature == target.signature }
        if !offered {
            result.errors.append("macOS does not currently offer \(target.summary) for this display.")
        }
        if !target.isUsableForDesktopGUI {
            result.errors.append("macOS marks \(target.summary) as unusable for the desktop.")
        }
        if !target.flags.contains(.valid) {
            result.errors.append("The display driver does not mark \(target.summary) as valid.")
        }
        if target.flags.contains(.neverShow) {
            result.errors.append("The display driver hides \(target.summary) from users.")
        }
        if let current, current.signature == target.signature {
            result.errors.append("\(target.summary) is already active.")
        }

        if target.flags.contains(.interlaced) {
            result.warnings.append("This is an interlaced mode and may flicker.")
        }
        if let current {
            let refresh = RefreshComparison.compare(from: current.refreshRate, to: target.refreshRate)
            if refresh.isReduction {
                result.warnings.append("\(refresh.summary).")
                result.requiresRefreshConfirmation = true
            } else if refresh == .unknown {
                result.warnings.append("The refresh rate after the change cannot be determined in advance.")
            }
        }
        if let native {
            if !target.logical.hasSameAspect(as: native) {
                result.warnings.append(
                    "\(target.logical.aspectLabel) mode on a \(native.aspectLabel) panel: expect black bars or stretching.")
            }
            let path = HiDPIDetection.renderingPath(for: target, native: native)
            if !target.hasNativeFlag {
                result.warnings.append(
                    "macOS does not mark this mode as the panel's native timing. The physical output resolution is not reported.")
            }
            if path == .upscaled1x || path == .upscaledHiDPI {
                result.warnings.append(
                    "The desktop is rendered at \(target.pixels) and scaled up to \(native), so text will look softer.")
            }
            if Double(target.logical.area) < Double(native.area) * 0.3 {
                let percent = Int((Double(target.logical.area) / Double(native.area) * 100).rounded())
                result.warnings.append("Workspace shrinks to \(percent)% of the native desktop area.")
            }
        }
        return result
    }
}
