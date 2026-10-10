import Foundation

/// A monitor model ScaleKit knows how to recognise.
public struct KnownMonitor: Sendable, Equatable {
    public var marketingName: String
    public var manufacturerCode: String
    public var productID: UInt32?
    public var productNameFragment: String
    /// From the manufacturer's specification; used only as a cross-check.
    public var specifiedNative: PixelSize

    public init(
        marketingName: String, manufacturerCode: String, productID: UInt32?,
        productNameFragment: String, specifiedNative: PixelSize
    ) {
        self.marketingName = marketingName
        self.manufacturerCode = manufacturerCode
        self.productID = productID
        self.productNameFragment = productNameFragment
        self.specifiedNative = specifiedNative
    }

    public static let asusVG34WQML5A = KnownMonitor(
        marketingName: "ASUS TUF Gaming VG34WQML5A",
        manufacturerCode: "AUS",
        productID: 0x342B,
        productNameFragment: "VG34WQML5A",
        specifiedNative: PixelSize(width: 3440, height: 1440)
    )
}

/// How confidently a connected display was identified as a known monitor.
public struct MonitorMatch: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var monitorName: String
    public var confidence: Confidence
    public var reasons: [String]

    public init(displayID: UInt32, monitorName: String, confidence: Confidence, reasons: [String]) {
        self.displayID = displayID
        self.monitorName = monitorName
        self.confidence = confidence
        self.reasons = reasons
    }
}

/// Finds connected displays and assembles everything known about them.
@MainActor
public final class DisplayDiscoveryService {
    private let hardware: DisplayHardware
    private let modes: DisplayModeService

    public init(hardware: DisplayHardware, modes: DisplayModeService) {
        self.hardware = hardware
        self.modes = modes
    }

    public func discover() -> [DisplayInfo] {
        let screens = hardware.screenSnapshots()
        let registry = hardware.registryAttributes()
        let displays = hardware.onlineDisplayIDs().compactMap { id -> DisplayInfo? in
            guard let raw = hardware.rawInfo(for: id) else { return nil }
            return Self.makeInfo(
                raw: raw,
                currentMode: modes.currentMode(for: id),
                allModes: modes.allModes(for: id),
                screen: screens.first { $0.displayID == id },
                registry: registry.first { $0.matches(vendorID: raw.vendorID, productID: raw.productID) }
            )
        }
        Log.discovery.info("Discovered \(displays.count) display(s)")
        // Main display first, then left-to-right.
        return displays.sorted { ($0.isMain ? 0 : 1, $0.bounds.x) < ($1.isMain ? 0 : 1, $1.bounds.x) }
    }

    public func display(withID id: UInt32) -> DisplayInfo? {
        discover().first { $0.id == id }
    }

    // MARK: - Pure assembly

    public nonisolated static func makeInfo(
        raw: RawDisplayInfo,
        currentMode: DisplayModeInfo?,
        allModes: [DisplayModeInfo],
        screen: ScreenSnapshot?,
        registry: RegistryDisplayAttributes?
    ) -> DisplayInfo {
        let identity = DisplayIdentity(
            vendorID: raw.vendorID, productID: raw.productID, serialNumber: raw.serialNumber, uuid: raw.uuid)

        let name: Fact<String> = if let screen {
            .measured(screen.localizedName, source: "NSScreen.localizedName")
        } else if let product = registry?.productName {
            .inferred(product, reason: "IORegistry ProductAttributes.ProductName (undocumented key)")
        } else {
            .unavailable("No AppKit screen and no registry name for this display")
        }

        let manufacturer: Fact<String> = if let code = identity.manufacturerCode {
            .inferred(
                PNPID.manufacturerName(forCode: code).map { "\($0) (\(code))" } ?? code,
                reason: String(format: "Decoded from EDID PNP vendor ID 0x%04X (CGDisplayVendorNumber)", raw.vendorID))
        } else {
            .unavailable("CGDisplayVendorNumber returned no decodable PNP ID")
        }

        let native = DisplayModeService.nativeResolution(from: allModes)
        let physicalSize: Fact<PhysicalSize> = raw.physicalSize.map {
            .measured($0, source: "CGDisplayScreenSize (EDID)")
        } ?? .unavailable("The display's EDID does not report a physical size")

        let density: Fact<Double> = if let size = raw.physicalSize, let nativeWidth = native.value?.width, size.widthMM > 0 {
            .inferred(
                Double(nativeWidth) / (size.widthMM / 25.4),
                reason: "Native width ÷ EDID physical width")
        } else {
            .unavailable("Needs both the native resolution and the physical size")
        }

        let logical: Fact<PixelSize> = currentMode.map {
            .measured($0.logical, source: "CGDisplayModeGetWidth/Height")
        } ?? .unavailable("CoreGraphics returned no current mode")
        let framebuffer: Fact<PixelSize> = currentMode.map {
            .measured($0.pixels, source: "CGDisplayModeGetPixelWidth/Height")
        } ?? .unavailable("CoreGraphics returned no current mode")

        let physicalOutput: Fact<PixelSize>
        if let currentMode, let nativeSize = native.value, currentMode.hasNativeFlag {
            physicalOutput = .inferred(
                nativeSize,
                reason: "Active mode carries kDisplayModeNativeFlag. macOS does not expose the link timing directly; confirm on the monitor's on-screen display.")
        } else {
            physicalOutput = .unavailable(
                "The active mode is not flagged native, and macOS does not report whether the Mac or the monitor scales it")
        }

        let scale: Fact<Double> = screen.map {
            .measured($0.backingScaleFactor, source: "NSScreen.backingScaleFactor")
        } ?? currentMode.map {
            .inferred($0.scaleFactor, reason: "Pixel width ÷ point width of the CoreGraphics mode (no AppKit screen)")
        } ?? .unavailable("No mode and no screen")

        let refresh: Fact<Double> = if let currentMode, currentMode.refreshRate > 0 {
            .measured(currentMode.refreshRate, source: "CGDisplayModeGetRefreshRate")
        } else {
            .unavailable("CoreGraphics reports 0 Hz for this mode (common for built-in and variable-rate panels)")
        }

        let maxFPS: Fact<Int> = screen.map {
            .measured($0.maximumFramesPerSecond, source: "NSScreen.maximumFramesPerSecond")
        } ?? .unavailable("No AppKit screen for this display")

        let connection: Fact<String> = if let label = registry?.connectionLabel {
            .inferred(label, reason: "IORegistry Transport key (undocumented)")
        } else if raw.isBuiltin {
            .inferred("Built-in", reason: "CGDisplayIsBuiltin")
        } else {
            .unavailable("macOS does not expose the connection type through a public API")
        }

        return DisplayInfo(
            id: raw.displayID, identity: identity, name: name, manufacturer: manufacturer,
            isMain: raw.isMain, isBuiltin: raw.isBuiltin, isActive: raw.isActive,
            isInMirrorSet: raw.isInMirrorSet, bounds: raw.bounds,
            physicalSize: physicalSize, pixelDensity: density, currentMode: currentMode,
            nativeResolution: native, logicalResolution: logical, framebufferResolution: framebuffer,
            physicalOutput: physicalOutput, backingScaleFactor: scale, refreshRate: refresh,
            maximumFramesPerSecond: maxFPS, connection: connection, registry: registry
        )
    }

    /// Identifies `monitor` among `displays`.
    public nonisolated static func match(
        _ monitor: KnownMonitor, in displays: [DisplayInfo]
    ) -> MonitorMatch? {
        let candidates = displays.map { display -> MonitorMatch in
            var reasons: [String] = []
            var points = 0
            if display.identity.manufacturerCode == monitor.manufacturerCode {
                points += 1
                reasons.append("EDID manufacturer is \(monitor.manufacturerCode)")
            }
            if let productID = monitor.productID, display.identity.productID == productID {
                points += 1
                reasons.append(String(format: "EDID product ID is 0x%04X", productID))
            }
            let names = [display.name.value, display.registry?.productName].compactMap { $0 }
            if names.contains(where: { $0.localizedCaseInsensitiveContains(monitor.productNameFragment) }) {
                points += 2
                reasons.append("Display name contains \"\(monitor.productNameFragment)\"")
            }
            if display.nativeResolution.value == monitor.specifiedNative {
                reasons.append("Native resolution matches the specification (\(monitor.specifiedNative))")
            } else if points > 0 {
                reasons.append("Native resolution \(display.nativeResolution.value?.description ?? "unknown") differs from the specification (\(monitor.specifiedNative))")
            }
            let confidence: Confidence = switch points {
            case 4: .high
            case 3: .high
            case 2: .medium
            case 1: .low
            default: .none
            }
            return MonitorMatch(
                displayID: display.id, monitorName: monitor.marketingName, confidence: confidence, reasons: reasons)
        }
        return candidates.filter { $0.confidence > .none }.max { $0.confidence < $1.confidence }
    }
}
