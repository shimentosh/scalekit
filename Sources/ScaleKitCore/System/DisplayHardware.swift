import Foundation

/// Basic CoreGraphics facts about one display.
public struct RawDisplayInfo: Sendable, Equatable {
    public var displayID: UInt32
    public var vendorID: UInt32
    public var productID: UInt32
    public var serialNumber: UInt32
    public var uuid: String?
    public var isMain: Bool
    public var isBuiltin: Bool
    public var isActive: Bool
    public var isInMirrorSet: Bool
    public var bounds: DisplayBounds
    /// Nil when the EDID does not report a size.
    public var physicalSize: PhysicalSize?

    public init(
        displayID: UInt32, vendorID: UInt32, productID: UInt32, serialNumber: UInt32, uuid: String?,
        isMain: Bool, isBuiltin: Bool, isActive: Bool, isInMirrorSet: Bool,
        bounds: DisplayBounds, physicalSize: PhysicalSize?
    ) {
        self.displayID = displayID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.uuid = uuid
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.isInMirrorSet = isInMirrorSet
        self.bounds = bounds
        self.physicalSize = physicalSize
    }
}

public enum DisplayHardwareError: Error, Equatable, Sendable, LocalizedError {
    case displayNotFound(UInt32)
    case modeNotFound(displayID: UInt32, modeID: Int32)
    case coreGraphics(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .displayNotFound(let id):
            "Display \(id) is no longer connected."
        case .modeNotFound(let id, let mode):
            "macOS no longer offers mode \(mode) for display \(id)."
        case .coreGraphics(let operation, let code):
            "\(operation) failed with CoreGraphics error \(code) (\(Self.describe(code)))."
        }
    }

    static func describe(_ code: Int32) -> String {
        switch code {
        case 1000: "failure"
        case 1001: "illegal argument"
        case 1002: "invalid connection"
        case 1003: "invalid context"
        case 1004: "cannot complete"
        case 1006: "not implemented"
        case 1007: "range check"
        case 1008: "type check"
        case 1010: "invalid operation"
        case 1011: "none available"
        default: "unknown"
        }
    }
}

/// The boundary between ScaleKit and the operating system's display stack.
///
/// The live implementation talks to CoreGraphics, AppKit and IOKit. Tests use a
/// fake so that every service can be exercised without touching real displays.
@MainActor
public protocol DisplayHardware: AnyObject {
    func onlineDisplayIDs() -> [UInt32]
    func rawInfo(for displayID: UInt32) -> RawDisplayInfo?
    func currentMode(for displayID: UInt32) -> DisplayModeInfo?
    /// With `includeLowResolutionDuplicates`, HiDPI modes are included.
    func allModes(for displayID: UInt32, includeLowResolutionDuplicates: Bool) -> [DisplayModeInfo]
    func applyMode(modeID: Int32, to displayID: UInt32, scope: ConfigurationScope) throws
    func restorePermanentConfiguration()
    func screenSnapshots() -> [ScreenSnapshot]
    func registryAttributes() -> [RegistryDisplayAttributes]
}
