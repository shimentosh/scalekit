import AppKit
import ScaleKitCore

/// Small, shared text formatters so every screen spells values the same way.
enum Format {
    /// "1×", "2×", "1.25×".
    static func scale(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.005 ? "\(Int(value.rounded()))×" : String(format: "%.2f×", value)
    }

    /// 1.5 → "150%".
    static func percent(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    static func size(_ size: PixelSize?) -> String {
        size.map(\.description) ?? "—"
    }

    static func value<T>(_ fact: Fact<T>, _ transform: (T) -> String) -> String {
        fact.value.map(transform) ?? "—"
    }

    /// Score points: "20" or "12.5".
    static func points(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.05 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
    }

    static func refresh(_ hertz: Double) -> String {
        RefreshRate.label(hertz)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension ApplyVerification.Level {
    /// Never reads as success unless the mode was confirmed by AppKit too.
    var label: String {
        switch self {
        case .verified: "Verified"
        case .partial: "Partially verified"
        case .failed: "Not verified"
        }
    }
}

extension DisplayInfo {
    /// Interface size of the active mode relative to native (1.0 = 100%).
    var currentUIScale: Double? {
        guard let mode = currentMode, let native = nativeResolution.value else { return nil }
        return RecommendationEngine.uiScale(of: mode, native: native)
    }

    /// "100%", or "168% (non-native)" when the active mode is not a clean mapping.
    var currentProfileLabel: String {
        guard let mode = currentMode, let native = nativeResolution.value else { return "Unknown" }
        let percent = Format.percent(RecommendationEngine.uiScale(of: mode, native: native))
        let path = HiDPIDetection.renderingPath(for: mode, native: native)
        var qualifiers: [String] = []
        if !mode.hasNativeFlag {
            qualifiers.append("non-native")
        } else if !path.isSharp {
            qualifiers.append("soft")
        }
        if !mode.logical.hasSameAspect(as: native) {
            qualifiers.append(mode.logical.aspectLabel)
        }
        return qualifiers.isEmpty ? percent : "\(percent) (\(qualifiers.joined(separator: ", ")))"
    }

    /// "ASUS" rather than "ASUS (AUS)".
    var manufacturerName: String? {
        guard let value = manufacturer.value else { return nil }
        if let range = value.range(of: " (") { return String(value[..<range.lowerBound]) }
        return value
    }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
