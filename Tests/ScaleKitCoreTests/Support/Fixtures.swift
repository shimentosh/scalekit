import Foundation
@testable import ScaleKitCore

// MARK: - Mode construction

/// Builds a mode compactly: logical size (points), backing size (pixels), refresh and raw IOKit flags.
func makeMode(
    _ id: Int32, _ logicalWidth: Int, _ logicalHeight: Int, _ pixelWidth: Int, _ pixelHeight: Int,
    _ hertz: Double, _ flags: UInt32, gui: Bool = true
) -> DisplayModeInfo {
    DisplayModeInfo(
        modeID: id,
        logical: PixelSize(width: logicalWidth, height: logicalHeight),
        pixels: PixelSize(width: pixelWidth, height: pixelHeight),
        refreshRate: hertz,
        flags: DisplayModeFlags(rawValue: flags),
        isUsableForDesktopGUI: gui)
}

/// Raw IOKit flag combinations seen on real hardware.
enum RawFlags {
    /// valid | safe | native
    static let native: UInt32 = 0x0200_0003
    /// valid | safe | default | native
    static let nativeDefault: UInt32 = 0x0200_0007
    /// valid | safe
    static let plain: UInt32 = 0x0000_0003
    /// valid only
    static let validOnly: UInt32 = 0x0000_0001
}

// MARK: - Monitor fixtures

/// A monitor described entirely by fixture data.
struct MonitorFixture: Sendable {
    var displayID: UInt32
    var vendorID: UInt32
    var productID: UInt32
    var serialNumber: UInt32
    var uuid: String?
    var name: String
    var isMain: Bool
    var isBuiltin: Bool = false
    var originX: Double
    var originY: Double
    var physicalSize: PhysicalSize?
    var modes: [DisplayModeInfo]
    var currentModeID: Int32?

    func mode(_ id: Int32) -> DisplayModeInfo {
        guard let mode = modes.first(where: { $0.modeID == id }) else {
            preconditionFailure("Fixture \(name) has no mode \(id)")
        }
        return mode
    }

    var currentMode: DisplayModeInfo? { currentModeID.map(mode) }
    var desktopModes: [DisplayModeInfo] { DisplayModeService.desktopModes(from: modes) }
    var nativeFact: Fact<PixelSize> { DisplayModeService.nativeResolution(from: modes) }
    var native: PixelSize {
        guard let value = nativeFact.value else { preconditionFailure("Fixture \(name) has no native resolution") }
        return value
    }

    var identity: DisplayIdentity {
        DisplayIdentity(vendorID: vendorID, productID: productID, serialNumber: serialNumber, uuid: uuid)
    }

    var key: String { identity.persistentKey }

    func raw(current: DisplayModeInfo?) -> RawDisplayInfo {
        RawDisplayInfo(
            displayID: displayID, vendorID: vendorID, productID: productID, serialNumber: serialNumber,
            uuid: uuid, isMain: isMain, isBuiltin: isBuiltin, isActive: true, isInMirrorSet: false,
            bounds: DisplayBounds(
                x: originX, y: originY,
                width: Double(current?.logical.width ?? 0), height: Double(current?.logical.height ?? 0)),
            physicalSize: physicalSize)
    }

    /// What AppKit would report while `mode` is active.
    func screen(for mode: DisplayModeInfo) -> ScreenSnapshot {
        ScreenSnapshot(
            displayID: displayID,
            localizedName: name,
            frame: DisplayBounds(
                x: originX, y: originY, width: Double(mode.logical.width), height: Double(mode.logical.height)),
            backingScaleFactor: Double(mode.pixels.width) / Double(mode.logical.width),
            maximumFramesPerSecond: Int(mode.refreshRate.rounded()))
    }

    /// A `DisplayInfo` assembled the same way discovery does it.
    func info(
        currentModeID override: Int32? = nil, withScreen: Bool = true, registry: RegistryDisplayAttributes? = nil
    ) -> DisplayInfo {
        let current = override.map(mode) ?? currentMode
        return DisplayDiscoveryService.makeInfo(
            raw: raw(current: current), currentMode: current, allModes: modes,
            screen: withScreen ? current.map(screen(for:)) : nil, registry: registry)
    }

    func context(
        referenceRefresh: Double? = nil, verified: Set<ModeSignature> = [], currentModeID override: Int32? = nil
    ) -> EvaluationContext {
        let current = override.map(mode) ?? currentMode
        return EvaluationContext(
            native: native, currentMode: current,
            referenceRefresh: referenceRefresh ?? current?.refreshRate ?? 60,
            verifiedSignatures: verified)
    }

    func evaluations(referenceRefresh: Double? = nil, verified: Set<ModeSignature> = []) -> [ProfileEvaluation] {
        ScalingProfileMapper.evaluate(
            modes: desktopModes, context: context(referenceRefresh: referenceRefresh, verified: verified))
    }
}

enum Fixtures {
    /// ASUS TUF Gaming VG34WQML5A, measured on the user's Mac (CG display 3).
    /// Mode IDs 95–97 for the small 1× modes are synthetic; everything else is measured.
    static let asus = MonitorFixture(
        displayID: 3, vendorID: 1715, productID: 13355, serialNumber: 0,
        uuid: "4A1B2C3D-0003-4000-8000-ASUSFIXTURE0", name: "VG34WQML5A",
        isMain: true, originX: 0, originY: 0,
        physicalSize: PhysicalSize(widthMM: 801.6, heightMM: 338.7),
        modes: [
            // 3440×1440 at 1×, native timing.
            makeMode(115, 3440, 1440, 3440, 1440, 250, RawFlags.native),
            makeMode(116, 3440, 1440, 3440, 1440, 250, RawFlags.nativeDefault),
            makeMode(117, 3440, 1440, 3440, 1440, 240, RawFlags.native),
            makeMode(118, 3440, 1440, 3440, 1440, 180, RawFlags.native),
            makeMode(119, 3440, 1440, 3440, 1440, 120, RawFlags.native),
            makeMode(120, 3440, 1440, 3440, 1440, 60, RawFlags.native),
            // 1720×720 HiDPI rendered at exactly the panel size (200%).
            makeMode(72, 1720, 720, 3440, 1440, 250, RawFlags.native),
            makeMode(76, 1720, 720, 3440, 1440, 240, RawFlags.native),
            makeMode(78, 1720, 720, 3440, 1440, 180, RawFlags.native),
            makeMode(80, 1720, 720, 3440, 1440, 120, RawFlags.native),
            makeMode(82, 1720, 720, 3440, 1440, 60, RawFlags.native),
            // 1720×720 at 1× (upscaled).
            makeMode(74, 1720, 720, 1720, 720, 250, RawFlags.plain),
            makeMode(81, 1720, 720, 1720, 720, 120, RawFlags.plain),
            makeMode(83, 1720, 720, 1720, 720, 60, RawFlags.plain),
            // Lower-resolution 21:9 modes at 1× (upscaled).
            makeMode(106, 2048, 858, 2048, 858, 250, RawFlags.plain),
            makeMode(110, 2048, 858, 2048, 858, 120, RawFlags.plain),
            makeMode(111, 2048, 858, 2048, 858, 60, RawFlags.plain),
            makeMode(88, 1920, 804, 1920, 804, 120, RawFlags.plain),
            makeMode(89, 1920, 804, 1920, 804, 60, RawFlags.plain),
            // 16:9 modes.
            makeMode(112, 2560, 1440, 2560, 1440, 120, RawFlags.plain),
            makeMode(114, 2560, 1440, 2560, 1440, 60, RawFlags.plain),
            makeMode(90, 1920, 1080, 3840, 2160, 120, RawFlags.plain),
            makeMode(91, 1920, 1080, 1920, 1080, 120, RawFlags.plain),
            makeMode(32, 1280, 720, 2560, 1440, 120, RawFlags.plain),
            // Small 21:9 1× modes (synthetic IDs).
            makeMode(95, 1600, 670, 1600, 670, 120, RawFlags.plain),
            makeMode(96, 1344, 562, 1344, 562, 120, RawFlags.plain),
            makeMode(97, 1280, 536, 1280, 536, 120, RawFlags.plain),
            // Low-resolution duplicate macOS marks unusable for the desktop.
            makeMode(232, 860, 360, 1720, 720, 120, RawFlags.validOnly, gui: false),
        ],
        currentModeID: 119)

    /// MSI MP223 (CG display 1), measured.
    static let msi = MonitorFixture(
        displayID: 1, vendorID: 13929, productID: 12473, serialNumber: 1,
        uuid: "4A1B2C3D-0001-4000-8000-MSIFIXTURE00", name: "MSI MP223",
        isMain: false, originX: 3440, originY: 0,
        physicalSize: PhysicalSize(widthMM: 476, heightMM: 268),
        modes: [
            makeMode(63, 1920, 1080, 1920, 1080, 100, RawFlags.nativeDefault),
            makeMode(64, 1920, 1080, 1920, 1080, 85, RawFlags.native),
            makeMode(65, 1920, 1080, 1920, 1080, 60, RawFlags.native),
            makeMode(13, 960, 540, 1920, 1080, 100, RawFlags.native),
            makeMode(34, 1280, 720, 1280, 720, 100, RawFlags.plain),
        ],
        currentModeID: 63)

    /// Synthetic 27-inch 4K panel whose scaled HiDPI modes carry the native flag.
    static let uhd = MonitorFixture(
        displayID: 7, vendorID: 0x10AC, productID: 0x4321, serialNumber: 77,
        uuid: "4A1B2C3D-0007-4000-8000-UHDFIXTURE00", name: "Synthetic 4K",
        isMain: false, originX: -3840, originY: 0,
        physicalSize: PhysicalSize(widthMM: 597, heightMM: 336),
        modes: [
            makeMode(1, 3840, 2160, 3840, 2160, 60, RawFlags.nativeDefault),
            makeMode(10, 3840, 2160, 3840, 2160, 30, RawFlags.native),
            makeMode(2, 1920, 1080, 3840, 2160, 60, RawFlags.native),   // 200% native HiDPI
            makeMode(3, 2560, 1440, 5120, 2880, 60, RawFlags.native),   // 150% supersampled
            makeMode(4, 3008, 1692, 6016, 3384, 60, RawFlags.native),   // ≈128% → 125% supersampled
            makeMode(5, 3200, 1800, 6400, 3600, 60, RawFlags.native),   // 120% supersampled
            makeMode(6, 2304, 1296, 4608, 2592, 60, RawFlags.native),   // ≈167% supersampled
            makeMode(7, 1280, 720, 2560, 1440, 60, RawFlags.plain),     // upscaled HiDPI
            makeMode(8, 2560, 1440, 2560, 1440, 60, RawFlags.plain),    // upscaled 1×
            makeMode(9, 1920, 1080, 1920, 1080, 60, RawFlags.plain),    // upscaled 1×
        ],
        currentModeID: 1)

    /// A display whose driver flags no mode as native.
    static let noNativeFlag = MonitorFixture(
        displayID: 9, vendorID: 0x1E6D, productID: 0x5B11, serialNumber: 9,
        uuid: nil, name: "Unflagged Panel",
        isMain: false, originX: 5360, originY: 0,
        physicalSize: nil,
        modes: [
            makeMode(40, 1920, 1080, 1920, 1080, 60, RawFlags.plain),
            makeMode(41, 1280, 720, 1280, 720, 60, RawFlags.plain),
            makeMode(42, 960, 540, 1920, 1080, 60, RawFlags.plain),
        ],
        currentModeID: 40)

    /// A display for which macOS reports no modes at all.
    static let noModes = MonitorFixture(
        displayID: 11, vendorID: 0x1E6D, productID: 0x0001, serialNumber: 11,
        uuid: nil, name: "Modeless",
        isMain: false, originX: 7280, originY: 0,
        physicalSize: nil, modes: [], currentModeID: nil)

    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
}

extension EnvironmentInfo {
    static let testFixture = EnvironmentInfo(
        macOSVersion: "27.0", macOSBuild: "27A100", hardwareModel: "Mac16,10", chip: "Apple M4",
        memoryGB: 16, architecture: "arm64")
}

// MARK: - Temporary directories

/// A unique directory under the system temporary directory. Call `cleanup()` (via `defer`).
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaleKitCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// A path whose parent is a regular file, so nothing can ever be created under it.
    func unwritableDirectory() throws -> URL {
        let blocker = url.appendingPathComponent("blocker-file")
        try Data("not a directory".utf8).write(to: blocker)
        return blocker.appendingPathComponent("Support", isDirectory: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Async helpers

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// Floating-point comparison for score arithmetic.
func approximately(_ value: Double?, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

/// Main-actor mutable storage that closures handed to MainActor services can capture.
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
