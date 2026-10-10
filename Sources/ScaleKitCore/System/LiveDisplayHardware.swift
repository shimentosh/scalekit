import AppKit
import ColorSync
import CoreGraphics
import IOKit

/// `DisplayHardware` backed by CoreGraphics, AppKit and IOKit.
@MainActor
public final class LiveDisplayHardware: DisplayHardware {
    public init() {}

    public func onlineDisplayIDs() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public func rawInfo(for displayID: UInt32) -> RawDisplayInfo? {
        guard onlineDisplayIDs().contains(displayID) else { return nil }
        let bounds = CGDisplayBounds(displayID)
        let size = CGDisplayScreenSize(displayID)
        var uuid: String?
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, cfUUID) as String?
        }
        return RawDisplayInfo(
            displayID: displayID,
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            uuid: uuid,
            isMain: CGDisplayIsMain(displayID) != 0,
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
            isActive: CGDisplayIsActive(displayID) != 0,
            isInMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0,
            bounds: DisplayBounds(
                x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height),
            physicalSize: size.width > 0 && size.height > 0
                ? PhysicalSize(widthMM: size.width, heightMM: size.height) : nil
        )
    }

    public func currentMode(for displayID: UInt32) -> DisplayModeInfo? {
        CGDisplayCopyDisplayMode(displayID).map(Self.info(from:))
    }

    public func allModes(for displayID: UInt32, includeLowResolutionDuplicates: Bool) -> [DisplayModeInfo] {
        cgModes(for: displayID, includeDuplicates: includeLowResolutionDuplicates).map(Self.info(from:))
    }

    public func applyMode(modeID: Int32, to displayID: UInt32, scope: ConfigurationScope) throws {
        guard onlineDisplayIDs().contains(displayID) else {
            throw DisplayHardwareError.displayNotFound(displayID)
        }
        // HiDPI modes are only listed when duplicates are requested.
        guard let mode = cgModes(for: displayID, includeDuplicates: true).first(where: { $0.ioDisplayModeID == modeID })
        else {
            throw DisplayHardwareError.modeNotFound(displayID: displayID, modeID: modeID)
        }

        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else {
            throw DisplayHardwareError.coreGraphics(operation: "CGBeginDisplayConfiguration", code: error.rawValue)
        }
        error = CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayHardwareError.coreGraphics(
                operation: "CGConfigureDisplayWithDisplayMode", code: error.rawValue)
        }
        let option: CGConfigureOption = switch scope {
        case .appOnly: .forAppOnly
        case .session: .forSession
        case .permanent: .permanently
        }
        error = CGCompleteDisplayConfiguration(config, option)
        guard error == .success else {
            throw DisplayHardwareError.coreGraphics(
                operation: "CGCompleteDisplayConfiguration", code: error.rawValue)
        }
        Log.configuration.info(
            "Applied mode \(modeID) to display \(displayID) scope=\(scope.rawValue, privacy: .public)")
    }

    public func restorePermanentConfiguration() {
        CGRestorePermanentDisplayConfiguration()
        Log.configuration.info("Restored permanent display configuration")
    }

    public func screenSnapshots() -> [ScreenSnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let frame = screen.frame
            return ScreenSnapshot(
                displayID: number.uint32Value,
                localizedName: screen.localizedName,
                frame: DisplayBounds(
                    x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                backingScaleFactor: screen.backingScaleFactor,
                maximumFramesPerSecond: screen.maximumFramesPerSecond
            )
        }
    }

    public func registryAttributes() -> [RegistryDisplayAttributes] {
        RegistryReader.displayAttributes()
    }

    // MARK: - Helpers

    private func cgModes(for displayID: UInt32, includeDuplicates: Bool) -> [CGDisplayMode] {
        let options: CFDictionary? = includeDuplicates
            ? [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            : nil
        return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
    }

    private static func info(from mode: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(
            modeID: mode.ioDisplayModeID,
            logical: PixelSize(width: mode.width, height: mode.height),
            pixels: PixelSize(width: mode.pixelWidth, height: mode.pixelHeight),
            refreshRate: mode.refreshRate,
            flags: DisplayModeFlags(rawValue: mode.ioFlags),
            isUsableForDesktopGUI: mode.isUsableForDesktopGUI()
        )
    }
}

/// Reads monitor attributes from IORegistry (`IOMobileFramebuffer` on Apple
/// silicon). The property keys are undocumented and may change between macOS
/// releases, so callers must treat the values as inferred.
enum RegistryReader {
    static func displayAttributes() -> [RegistryDisplayAttributes] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator)
            == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var results: [RegistryDisplayAttributes] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let attributes = property(service, "DisplayAttributes") as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any]
            else { continue }
            let transport = property(service, "Transport") as? [String: Any]
            // Serial numbers are deliberately not read: reports may be shared.
            results.append(RegistryDisplayAttributes(
                productName: product["ProductName"] as? String,
                manufacturerCode: product["ManufacturerID"] as? String,
                legacyManufacturerID: (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                productID: (product["ProductID"] as? NSNumber)?.uint32Value,
                transportUpstream: transport?["Upstream"] as? String,
                transportDownstream: transport?["Downstream"] as? String,
                maximumRefreshRate: (attributes["MaximumRefreshRate"] as? NSNumber)?.doubleValue,
                minimumRefreshRate: (attributes["MinimumRefreshRate"] as? NSNumber)?.doubleValue,
                supportsVariableRefreshRate: (attributes["SupportsVariableRefreshRate"] as? NSNumber)?.boolValue,
                supportsHDR: (attributes["SupportsPQEOTF"] as? NSNumber)?.boolValue,
                yearOfManufacture: (product["YearOfManufacture"] as? NSNumber)?.intValue,
                weekOfManufacture: (product["WeekOfManufacture"] as? NSNumber)?.intValue
            ))
        }
        return results
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively))
    }
}
