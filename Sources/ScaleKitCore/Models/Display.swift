import Foundation

/// Decodes the three-letter PNP manufacturer ID packed into an EDID vendor number.
public enum PNPID {
    public static func decode(_ vendorID: UInt32) -> String? {
        guard vendorID > 0, vendorID <= 0x7FFF else { return nil }
        let codes = [(vendorID >> 10) & 0x1F, (vendorID >> 5) & 0x1F, vendorID & 0x1F]
        guard codes.allSatisfy({ (1...26).contains($0) }) else { return nil }
        return String(codes.compactMap { UnicodeScalar(64 + $0).map(Character.init) })
    }

    private static let manufacturers: [String: String] = [
        "AUS": "ASUS", "MSI": "MSI", "APP": "Apple", "DEL": "Dell", "GSM": "LG", "SAM": "Samsung",
        "SNY": "Sony", "BNQ": "BenQ", "ACR": "Acer", "AOC": "AOC", "HWP": "HP", "HPN": "HP",
        "LEN": "Lenovo", "PHL": "Philips", "VSC": "ViewSonic", "GBT": "Gigabyte", "ENC": "EIZO",
        "NEC": "NEC", "HKC": "HKC", "KOS": "KOORUI", "AOR": "AORUS",
    ]

    public static func manufacturerName(forCode code: String) -> String? {
        manufacturers[code]
    }
}

/// Values that identify a physical monitor.
public struct DisplayIdentity: Codable, Hashable, Sendable {
    public let vendorID: UInt32
    public let productID: UInt32
    public let serialNumber: UInt32
    /// `CGDisplayCreateUUIDFromDisplayID`; stable across reconnects for the same monitor.
    public let uuid: String?

    public init(vendorID: UInt32, productID: UInt32, serialNumber: UInt32, uuid: String?) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.uuid = uuid
    }

    public var manufacturerCode: String? { PNPID.decode(vendorID) }

    /// Key used to store backups and verification records for this monitor.
    public var persistentKey: String {
        uuid ?? String(format: "%04x-%04x-%x", vendorID, productID, serialNumber)
    }

    public var hexDescription: String {
        String(format: "vendor 0x%04X · product 0x%04X", vendorID, productID)
    }
}

/// Monitor attributes read from IORegistry. The keys are undocumented, so every
/// value derived from them is reported as inferred.
public struct RegistryDisplayAttributes: Codable, Sendable, Equatable {
    public var productName: String?
    public var manufacturerCode: String?
    public var legacyManufacturerID: UInt32?
    public var productID: UInt32?
    public var transportUpstream: String?
    public var transportDownstream: String?
    public var maximumRefreshRate: Double?
    public var minimumRefreshRate: Double?
    public var supportsVariableRefreshRate: Bool?
    public var supportsHDR: Bool?
    public var yearOfManufacture: Int?
    public var weekOfManufacture: Int?

    public init(
        productName: String? = nil, manufacturerCode: String? = nil, legacyManufacturerID: UInt32? = nil,
        productID: UInt32? = nil, transportUpstream: String? = nil, transportDownstream: String? = nil,
        maximumRefreshRate: Double? = nil, minimumRefreshRate: Double? = nil,
        supportsVariableRefreshRate: Bool? = nil, supportsHDR: Bool? = nil,
        yearOfManufacture: Int? = nil, weekOfManufacture: Int? = nil
    ) {
        self.productName = productName
        self.manufacturerCode = manufacturerCode
        self.legacyManufacturerID = legacyManufacturerID
        self.productID = productID
        self.transportUpstream = transportUpstream
        self.transportDownstream = transportDownstream
        self.maximumRefreshRate = maximumRefreshRate
        self.minimumRefreshRate = minimumRefreshRate
        self.supportsVariableRefreshRate = supportsVariableRefreshRate
        self.supportsHDR = supportsHDR
        self.yearOfManufacture = yearOfManufacture
        self.weekOfManufacture = weekOfManufacture
    }

    /// For example "HDMI (DP link from the Mac)".
    public var connectionLabel: String? {
        switch (transportUpstream, transportDownstream) {
        case let (up?, down?) where up != down: "\(down) (\(up) link from the Mac)"
        case let (_, down?): down
        case let (up?, nil): up
        default: nil
        }
    }

    public func matches(vendorID: UInt32, productID: UInt32) -> Bool {
        legacyManufacturerID == vendorID && self.productID == productID
    }
}

/// What AppKit reports for a screen.
public struct ScreenSnapshot: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var localizedName: String
    public var frame: DisplayBounds
    public var backingScaleFactor: Double
    public var maximumFramesPerSecond: Int

    public init(
        displayID: UInt32, localizedName: String, frame: DisplayBounds,
        backingScaleFactor: Double, maximumFramesPerSecond: Int
    ) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.frame = frame
        self.backingScaleFactor = backingScaleFactor
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}

/// Everything ScaleKit knows about one connected display, with provenance.
public struct DisplayInfo: Codable, Sendable, Identifiable, Equatable {
    /// `CGDirectDisplayID`. Valid only while the display stays connected.
    public var id: UInt32
    public var identity: DisplayIdentity
    public var name: Fact<String>
    public var manufacturer: Fact<String>
    public var isMain: Bool
    public var isBuiltin: Bool
    public var isActive: Bool
    public var isInMirrorSet: Bool
    public var bounds: DisplayBounds
    public var physicalSize: Fact<PhysicalSize>
    public var pixelDensity: Fact<Double>
    public var currentMode: DisplayModeInfo?
    /// Panel resolution.
    public var nativeResolution: Fact<PixelSize>
    /// Desktop size in points ("looks like").
    public var logicalResolution: Fact<PixelSize>
    /// Size of the rendered backing store in pixels.
    public var framebufferResolution: Fact<PixelSize>
    /// Resolution of the signal sent to the monitor.
    public var physicalOutput: Fact<PixelSize>
    public var backingScaleFactor: Fact<Double>
    public var refreshRate: Fact<Double>
    public var maximumFramesPerSecond: Fact<Int>
    public var connection: Fact<String>
    public var registry: RegistryDisplayAttributes?

    public init(
        id: UInt32, identity: DisplayIdentity, name: Fact<String>, manufacturer: Fact<String>,
        isMain: Bool, isBuiltin: Bool, isActive: Bool, isInMirrorSet: Bool, bounds: DisplayBounds,
        physicalSize: Fact<PhysicalSize>, pixelDensity: Fact<Double>, currentMode: DisplayModeInfo?,
        nativeResolution: Fact<PixelSize>, logicalResolution: Fact<PixelSize>,
        framebufferResolution: Fact<PixelSize>, physicalOutput: Fact<PixelSize>,
        backingScaleFactor: Fact<Double>, refreshRate: Fact<Double>, maximumFramesPerSecond: Fact<Int>,
        connection: Fact<String>, registry: RegistryDisplayAttributes?
    ) {
        self.id = id
        self.identity = identity
        self.name = name
        self.manufacturer = manufacturer
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.isInMirrorSet = isInMirrorSet
        self.bounds = bounds
        self.physicalSize = physicalSize
        self.pixelDensity = pixelDensity
        self.currentMode = currentMode
        self.nativeResolution = nativeResolution
        self.logicalResolution = logicalResolution
        self.framebufferResolution = framebufferResolution
        self.physicalOutput = physicalOutput
        self.backingScaleFactor = backingScaleFactor
        self.refreshRate = refreshRate
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.connection = connection
        self.registry = registry
    }

    public var displayName: String { name.value ?? "Display \(id)" }
    public var key: String { identity.persistentKey }
}
