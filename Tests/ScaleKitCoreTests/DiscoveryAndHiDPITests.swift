import Foundation
import Testing
@testable import ScaleKitCore

@Suite("Identification and geometry")
struct IdentificationTests {
    @Test("PNP vendor IDs decode to three-letter codes")
    func pnpDecode() {
        #expect(PNPID.decode(1715) == "AUS")
        #expect(PNPID.decode(0x06B3) == "AUS")
        #expect(PNPID.decode(13929) == "MSI")
        #expect(PNPID.decode(0x10AC) == "DEL")
        #expect(PNPID.decode(0x0610) == "APP")
    }

    @Test("Invalid vendor IDs decode to nil", arguments: [0, 0x8000, 0xFFFF_FFFF, 0x0001, 0x0400, (27 << 10) | (1 << 5) | 1] as [UInt32])
    func pnpInvalid(vendorID: UInt32) {
        #expect(PNPID.decode(vendorID) == nil)
    }

    @Test("Manufacturer names for known codes")
    func manufacturerNames() {
        #expect(PNPID.manufacturerName(forCode: "AUS") == "ASUS")
        #expect(PNPID.manufacturerName(forCode: "MSI") == "MSI")
        #expect(PNPID.manufacturerName(forCode: "ZZZ") == nil)
        #expect(Fixtures.asus.identity.manufacturerCode == "AUS")
    }

    @Test("Aspect labels", arguments: [
        (3440, 1440, "21:9"), (2560, 1080, "21:9"), (1720, 720, "21:9"), (2048, 858, "21:9"),
        (1920, 1080, "16:9"), (3840, 2160, "16:9"), (2560, 1600, "16:10"), (1600, 1200, "4:3"),
        (1280, 1024, "5:4"), (5120, 1440, "32:9"), (3000, 2000, "3:2"), (1000, 1000, "1.00:1"),
    ] as [(Int, Int, String)])
    func aspectLabels(width: Int, height: Int, label: String) {
        #expect(PixelSize(width: width, height: height).aspectLabel == label)
    }

    @Test("Aspect comparison tolerates rounding but not a different shape")
    func sameAspect() {
        let panel = PixelSize(width: 3440, height: 1440)
        #expect(PixelSize(width: 2048, height: 858).hasSameAspect(as: panel))
        #expect(PixelSize(width: 1344, height: 562).hasSameAspect(as: panel))
        #expect(!PixelSize(width: 2560, height: 1440).hasSameAspect(as: panel))
        #expect(!PixelSize(width: 1920, height: 0).hasSameAspect(as: panel))
        #expect(PixelSize(width: 10, height: 0).aspectRatio == 0)
    }

    @Test("Physical size and diagonal of the ASUS panel")
    func physicalSize() throws {
        let size = try #require(Fixtures.asus.physicalSize)
        #expect(abs(size.diagonalInches - 34.26) < 0.01)
        #expect(size.description == "802 × 339 mm (34.3″)")
    }

    @Test("Display bounds round to a pixel size")
    func bounds() {
        #expect(DisplayBounds(x: 0, y: 0, width: 1719.6, height: 720.4).size == PixelSize(width: 1720, height: 720))
    }

    @Test("Fact with a nil value is always unavailable")
    func factNil() {
        let fact = Fact<Int>(value: nil, provenance: .measured, source: "made up")
        #expect(fact.provenance == .unavailable)
        #expect(Fact<Int>(value: 3, provenance: .inferred, source: "x").provenance == .inferred)
        #expect(Fact<Int>.unavailable("why").value == nil)
        let mapped = Fact<Int>.measured(2, source: "api").map { $0 * 10 }
        #expect(mapped.value == 20)
        #expect(mapped.provenance == .measured)
        #expect(mapped.source == "api")
        #expect(Provenance.allCases.map(\.label) == ["Measured", "Inferred", "Unavailable"])
    }

    @Test("Registry connection labels")
    func connectionLabel() {
        #expect(RegistryDisplayAttributes(transportUpstream: "DP", transportDownstream: "HDMI").connectionLabel == "HDMI (DP link from the Mac)")
        #expect(RegistryDisplayAttributes(transportUpstream: "DP", transportDownstream: "DP").connectionLabel == "DP")
        #expect(RegistryDisplayAttributes(transportUpstream: "DP").connectionLabel == "DP")
        #expect(RegistryDisplayAttributes().connectionLabel == nil)
        let registry = RegistryDisplayAttributes(legacyManufacturerID: 1715, productID: 13355)
        #expect(registry.matches(vendorID: 1715, productID: 13355))
        #expect(!registry.matches(vendorID: 13929, productID: 13355))
    }
}

@Suite("HiDPI detection")
struct HiDPIDetectionTests {
    let asus = Fixtures.asus
    let uhd = Fixtures.uhd

    @Test("Rendering paths")
    func renderingPaths() {
        let native = asus.native
        #expect(HiDPIDetection.renderingPath(for: asus.mode(119), native: native) == .native1x)
        #expect(HiDPIDetection.renderingPath(for: asus.mode(80), native: native) == .nativeHiDPI)
        #expect(HiDPIDetection.renderingPath(for: uhd.mode(3), native: uhd.native) == .supersampledHiDPI)
        #expect(HiDPIDetection.renderingPath(for: asus.mode(90), native: native) == .supersampledHiDPI)
        #expect(HiDPIDetection.renderingPath(for: asus.mode(32), native: native) == .upscaledHiDPI)
        #expect(HiDPIDetection.renderingPath(for: asus.mode(110), native: native) == .upscaled1x)
        #expect(HiDPIDetection.renderingPath(for: asus.mode(81), native: native) == .upscaled1x)
    }

    @Test("Unknown rendering path without a usable native size, or for an oversize 1× mode")
    func unknownPath() {
        #expect(HiDPIDetection.renderingPath(for: asus.mode(80), native: nil) == .unknown)
        #expect(HiDPIDetection.renderingPath(for: asus.mode(80), native: PixelSize(width: 0, height: 0)) == .unknown)
        let oversize = makeMode(500, 3840, 2160, 3840, 2160, 60, RawFlags.plain)
        #expect(HiDPIDetection.renderingPath(for: oversize, native: asus.native) == .unknown)
    }

    @Test("Only native and supersampled paths are sharp")
    func sharpness() {
        #expect(RenderingPath.native1x.isSharp)
        #expect(RenderingPath.nativeHiDPI.isSharp)
        #expect(RenderingPath.supersampledHiDPI.isSharp)
        #expect(!RenderingPath.upscaledHiDPI.isSharp)
        #expect(!RenderingPath.upscaled1x.isSharp)
        #expect(!RenderingPath.unknown.isSharp)
    }

    @Test("CoreGraphics and AppKit agreeing gives high confidence")
    func agree() {
        let status = HiDPIDetection.status(currentMode: asus.mode(80), screen: asus.screen(for: asus.mode(80)))
        #expect(status.isActive == true)
        #expect(status.confidence == .high)
        #expect(status.modeScale == 2)
        #expect(status.screenScale == 2)
        #expect(status.label == "HiDPI (2×)")

        let oneX = HiDPIDetection.status(currentMode: asus.mode(119), screen: asus.screen(for: asus.mode(119)))
        #expect(oneX.isActive == false)
        #expect(oneX.confidence == .high)
        #expect(oneX.label == "Not HiDPI (1×)")
    }

    @Test("Disagreement gives low confidence")
    func disagree() {
        let status = HiDPIDetection.status(currentMode: asus.mode(80), screen: asus.screen(for: asus.mode(119)))
        #expect(status.confidence == .low)
        #expect(status.isActive == true)
        #expect(status.explanation.contains("AppKit reports 1×"))
    }

    @Test("CoreGraphics only gives medium confidence")
    func noScreen() {
        let status = HiDPIDetection.status(currentMode: asus.mode(80), screen: nil)
        #expect(status.confidence == .medium)
        #expect(status.isActive == true)
        #expect(status.screenScale == nil)
    }

    @Test("AppKit only gives low confidence")
    func screenOnly() {
        let status = HiDPIDetection.status(currentMode: nil, screen: asus.screen(for: asus.mode(80)))
        #expect(status.confidence == .low)
        #expect(status.isActive == true)
        #expect(status.modeScale == nil)
    }

    @Test("Neither source gives no confidence")
    func nothing() {
        let status = HiDPIDetection.status(currentMode: nil, screen: nil)
        #expect(status.confidence == .none)
        #expect(status.isActive == nil)
        #expect(status.label == "Unknown")
        #expect(Confidence.none < .low && Confidence.low < .medium && Confidence.medium < .high)
    }

    @Test("ASUS HiDPI availability: only 1720×720 at native resolution, no aspect-correct scaled modes")
    func asusAvailability() {
        let availability = HiDPIDetection.availability(modes: asus.modes, native: asus.native)
        #expect(availability.hiDPIModeCount == 7)
        #expect(Set(availability.nativeHiDPIModes.map(\.modeID)) == [72, 76, 78, 80, 82])
        #expect(availability.supersampledHiDPIModes.map(\.modeID) == [90])
        #expect(Set(availability.aspectMatchedHiDPIModes.map(\.modeID)) == [72, 76, 78, 80, 82])
        #expect(availability.summary.contains("3 HiDPI resolutions offered."))
        #expect(availability.summary.contains("At native resolution: 1720 × 720."))
        #expect(availability.summary.contains("No scaled (downsampled) HiDPI modes with the panel's aspect ratio."))
    }

    @Test("4K HiDPI availability includes aspect-correct scaled modes")
    func uhdAvailability() {
        let availability = HiDPIDetection.availability(modes: uhd.modes, native: uhd.native)
        #expect(Set(availability.supersampledHiDPIModes.map(\.modeID)) == [3, 4, 5, 6])
        #expect(!availability.summary.contains("No scaled"))
    }

    @Test("A display with no HiDPI modes says so")
    func noHiDPI() {
        let modes = Fixtures.asus.modes.filter { !$0.isHiDPI }
        let availability = HiDPIDetection.availability(modes: modes, native: asus.native)
        #expect(availability.hiDPIModeCount == 0)
        #expect(availability.summary == "macOS offers no HiDPI modes for this display.")
    }
}

@Suite("Display discovery")
struct DiscoveryTests {
    let asus = Fixtures.asus

    @Test("Provenance for the ASUS with an AppKit screen")
    func asusProvenance() throws {
        let info = asus.info()
        #expect(info.id == 3)
        #expect(info.name == .measured("VG34WQML5A", source: "NSScreen.localizedName"))
        #expect(info.manufacturer.value == "ASUS (AUS)")
        #expect(info.manufacturer.provenance == .inferred)
        #expect(info.physicalSize.provenance == .measured)
        let density = try #require(info.pixelDensity.value)
        #expect(abs(density - 109.0) < 0.1)
        #expect(info.pixelDensity.provenance == .inferred)
        #expect(info.nativeResolution.value == PixelSize(width: 3440, height: 1440))
        #expect(info.nativeResolution.provenance == .measured)
        #expect(info.logicalResolution.provenance == .measured)
        #expect(info.framebufferResolution.value == PixelSize(width: 3440, height: 1440))
        #expect(info.physicalOutput.value == PixelSize(width: 3440, height: 1440))
        #expect(info.physicalOutput.provenance == .inferred)
        #expect(info.backingScaleFactor == .measured(1, source: "NSScreen.backingScaleFactor"))
        #expect(info.refreshRate.value == 120)
        #expect(info.refreshRate.provenance == .measured)
        #expect(info.maximumFramesPerSecond.value == 120)
        #expect(info.connection.provenance == .unavailable)
        #expect(info.isMain)
        #expect(info.key == asus.key)
    }

    @Test("Physical output is unavailable when the active mode is not flagged native")
    func nonNativeOutput() {
        let info = asus.info(currentModeID: 110)
        #expect(info.physicalOutput.value == nil)
        #expect(info.physicalOutput.provenance == .unavailable)
        #expect(info.nativeResolution.value == PixelSize(width: 3440, height: 1440))
    }

    @Test("Refresh is unavailable when CoreGraphics reports 0 Hz")
    func zeroRefresh() {
        let builtIn = MonitorFixture(
            displayID: 20, vendorID: 0x0610, productID: 0xA050, serialNumber: 0, uuid: nil, name: "Built-in Retina Display",
            isMain: true, isBuiltin: true, originX: 0, originY: 0,
            physicalSize: PhysicalSize(widthMM: 302, heightMM: 196),
            modes: [makeMode(1, 1512, 982, 3024, 1964, 0, RawFlags.nativeDefault)], currentModeID: 1)
        let info = builtIn.info()
        #expect(info.refreshRate.provenance == .unavailable)
        #expect(info.refreshRate.value == nil)
        #expect(info.connection == .inferred("Built-in", reason: "CGDisplayIsBuiltin"))
        #expect(info.backingScaleFactor.value == 2)
    }

    @Test("Without AppKit, the name comes from the registry (inferred) or is unavailable")
    func nameFallbacks() {
        let registry = RegistryDisplayAttributes(
            productName: "VG34WQML5A", legacyManufacturerID: 1715, productID: 13355,
            transportUpstream: "DP", transportDownstream: "DP")
        let viaRegistry = asus.info(withScreen: false, registry: registry)
        #expect(viaRegistry.name.value == "VG34WQML5A")
        #expect(viaRegistry.name.provenance == .inferred)
        #expect(viaRegistry.backingScaleFactor.provenance == .inferred)
        #expect(viaRegistry.backingScaleFactor.value == 1)
        #expect(viaRegistry.maximumFramesPerSecond.provenance == .unavailable)
        #expect(viaRegistry.connection == .inferred("DP", reason: "IORegistry Transport key (undocumented)"))

        let anonymous = asus.info(withScreen: false)
        #expect(anonymous.name.provenance == .unavailable)
        #expect(anonymous.displayName == "Display 3")
    }

    @Test("Without a current mode, mode-derived facts are unavailable")
    func noCurrentMode() {
        let info = DisplayDiscoveryService.makeInfo(
            raw: asus.raw(current: nil), currentMode: nil, allModes: asus.modes, screen: nil, registry: nil)
        #expect(info.logicalResolution.provenance == .unavailable)
        #expect(info.framebufferResolution.provenance == .unavailable)
        #expect(info.physicalOutput.provenance == .unavailable)
        #expect(info.refreshRate.provenance == .unavailable)
        #expect(info.backingScaleFactor.provenance == .unavailable)
        #expect(info.nativeResolution.value == PixelSize(width: 3440, height: 1440))
    }

    @Test("Missing EDID size makes size and density unavailable")
    func noPhysicalSize() {
        let info = Fixtures.noNativeFlag.info()
        #expect(info.physicalSize.provenance == .unavailable)
        #expect(info.pixelDensity.provenance == .unavailable)
    }

    @Test("The ASUS fixture is identified with high confidence")
    func matchASUS() throws {
        let match = try #require(DisplayDiscoveryService.match(.asusVG34WQML5A, in: [asus.info()]))
        #expect(match.displayID == 3)
        #expect(match.confidence == .high)
        #expect(match.monitorName == "ASUS TUF Gaming VG34WQML5A")
        #expect(match.reasons.contains("EDID manufacturer is AUS"))
        #expect(match.reasons.contains("EDID product ID is 0x342B"))
        #expect(match.reasons.contains { $0.contains("Display name contains") })
        #expect(match.reasons.contains { $0.contains("matches the specification") })
    }

    @Test("Only the MSI connected: no match")
    func matchMSIOnly() {
        #expect(DisplayDiscoveryService.match(.asusVG34WQML5A, in: [Fixtures.msi.info()]) == nil)
        #expect(DisplayDiscoveryService.match(.asusVG34WQML5A, in: []) == nil)
    }

    @Test("The ASUS is picked out among several displays")
    func matchAmongMany() {
        let match = DisplayDiscoveryService.match(.asusVG34WQML5A, in: [Fixtures.msi.info(), Fixtures.uhd.info(), asus.info()])
        #expect(match?.displayID == 3)
    }

    @Test("Without a name, EDID IDs alone give medium confidence; the registry name restores high")
    func matchConfidenceLevels() {
        #expect(DisplayDiscoveryService.match(.asusVG34WQML5A, in: [asus.info(withScreen: false)])?.confidence == .medium)
        let registry = RegistryDisplayAttributes(productName: "VG34WQML5A", legacyManufacturerID: 1715, productID: 13355)
        #expect(DisplayDiscoveryService.match(.asusVG34WQML5A, in: [asus.info(withScreen: false, registry: registry)])?.confidence == .high)
    }
}

@MainActor
@Suite("Discovery through fake hardware")
struct DiscoveryServiceTests {
    @Test("Discover lists the main display first, then left to right, and attaches registry data")
    func discover() {
        let fake = FakeDisplayHardware(monitors: [Fixtures.msi, Fixtures.uhd, Fixtures.asus])
        fake.registry = [RegistryDisplayAttributes(
            productName: "VG34WQML5A", legacyManufacturerID: 1715, productID: 13355,
            transportUpstream: "DP", transportDownstream: "DP", maximumRefreshRate: 280,
            supportsVariableRefreshRate: true)]
        let modes = DisplayModeService(hardware: fake)
        let discovery = DisplayDiscoveryService(hardware: fake, modes: modes)
        let displays = discovery.discover()
        #expect(displays.map(\.id) == [3, 7, 1])
        #expect(displays.first?.registry?.maximumRefreshRate == 280)
        #expect(displays.last?.registry == nil)
        #expect(discovery.display(withID: 1)?.displayName == "MSI MP223")
        #expect(discovery.display(withID: 99) == nil)
    }

    @Test("HiDPI service combines the fake's mode and screen")
    func hiDPIService() {
        let fake = FakeDisplayHardware()
        let modes = DisplayModeService(hardware: fake)
        let hiDPI = HiDPIDetectionService(hardware: fake, modes: modes)
        #expect(hiDPI.status(for: 3).confidence == .high)
        #expect(hiDPI.status(for: 3).isActive == false)
        fake.hiddenScreens = [3]
        #expect(hiDPI.status(for: 3).confidence == .medium)
        #expect(hiDPI.availability(for: 3).nativeHiDPIModes.count == 5)
        #expect(hiDPI.availability(for: 1).nativeHiDPIModes.map(\.modeID) == [13])
    }
}
