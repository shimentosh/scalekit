import Foundation
import Testing
@testable import ScaleKitCore

@Suite("Mode validation")
struct ModeValidationTests {
    let asus = Fixtures.asus

    private func validate(
        _ target: DisplayModeInfo, extra: [DisplayModeInfo] = [], current: DisplayModeInfo?? = .none,
        native: PixelSize?? = .none
    ) -> ModeValidation {
        ModeValidator.validate(
            target,
            available: asus.desktopModes + extra,
            current: current ?? asus.currentMode,
            native: native ?? asus.native)
    }

    // MARK: Errors

    @Test("A mode macOS does not offer is rejected")
    func notOffered() {
        // A 125% HiDPI mode (2752 × 1152) is exactly what the user wants, but macOS does not generate it.
        let invented = makeMode(999, 2752, 1152, 5504, 2304, 120, RawFlags.native)
        let result = validate(invented)
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("does not currently offer") })
    }

    @Test("A known signature under a stale mode ID is not treated as offered")
    func staleModeID() {
        let real = asus.mode(80)
        let stale = DisplayModeInfo(
            modeID: 9999, logical: real.logical, pixels: real.pixels, refreshRate: real.refreshRate,
            flags: real.flags, isUsableForDesktopGUI: true)
        #expect(validate(stale).errors.contains { $0.contains("does not currently offer") })
    }

    @Test("A mode that is not usable for the desktop GUI is rejected")
    func notDesktopUsable() {
        let result = validate(asus.mode(232))
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("unusable for the desktop") })
    }

    @Test("A mode without the valid flag is rejected even if listed")
    func missingValidFlag() {
        let invalid = makeMode(300, 2560, 1072, 2560, 1072, 120, 0x0200_0002) // safe | native, no valid
        let result = validate(invalid, extra: [invalid])
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("does not mark") && $0.contains("as valid") })
        #expect(!result.errors.contains { $0.contains("does not currently offer") })
    }

    @Test("A mode the driver hides with neverShow is rejected")
    func neverShow() {
        let hidden = makeMode(301, 2560, 1072, 2560, 1072, 120, 0x0000_0083) // valid | safe | neverShow
        let result = validate(hidden, extra: [hidden])
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("hides") })
    }

    @Test("The already-active mode is rejected")
    func alreadyActive() {
        let result = validate(asus.mode(119))
        #expect(!result.isValid)
        #expect(result.errors.contains { $0.contains("already active") })
    }

    // MARK: Warnings

    @Test("Lowering the refresh rate warns and requires explicit confirmation")
    func refreshReduction() {
        let result = validate(asus.mode(82)) // 1720×720 HiDPI @ 60 Hz from 120 Hz
        #expect(result.isValid)
        #expect(result.requiresRefreshConfirmation)
        #expect(result.warnings.contains("Drops from 120 Hz to 60 Hz."))
    }

    @Test("Raising or keeping the refresh rate needs no confirmation")
    func refreshIncrease() {
        for id: Int32 in [72, 80] {
            let result = validate(asus.mode(id))
            #expect(!result.requiresRefreshConfirmation)
            #expect(!result.warnings.contains { $0.contains("Drops") })
        }
    }

    @Test("An unknown target refresh rate is called out")
    func unknownRefresh() {
        let zeroHz = makeMode(302, 1720, 720, 3440, 1440, 0, RawFlags.native)
        let result = validate(zeroHz, extra: [zeroHz])
        #expect(result.warnings.contains { $0.contains("cannot be determined") })
        #expect(!result.requiresRefreshConfirmation)
    }

    @Test("An aspect-ratio mismatch warns about black bars or stretching")
    func aspectMismatch() {
        let result = validate(asus.mode(91)) // 1920×1080 on a 21:9 panel
        #expect(result.isValid)
        #expect(result.warnings.contains { $0.contains("16:9 mode on a 21:9 panel") })
    }

    @Test("A mode without the native flag warns that physical output is unknown")
    func nonNative() {
        let result = validate(asus.mode(110)) // 2048×858
        #expect(result.warnings.contains { $0.contains("native timing") })
    }

    @Test("Upscaled 1× and upscaled HiDPI modes warn about soft text", arguments: [Int32(110), 81, 32])
    func upscaled(id: Int32) {
        let result = validate(asus.mode(id))
        #expect(result.warnings.contains { $0.contains("scaled up to 3440 × 1440") })
    }

    @Test("A much smaller workspace is called out")
    func smallWorkspace() {
        let result = validate(asus.mode(80))
        #expect(result.warnings.contains("Workspace shrinks to 25% of the native desktop area."))
        // 2048×858 is 35% of the area: above the 30% threshold.
        #expect(!validate(asus.mode(110)).warnings.contains { $0.contains("Workspace") })
    }

    @Test("Interlaced modes warn about flicker")
    func interlaced() {
        let interlaced = makeMode(303, 1920, 804, 1920, 804, 60, 0x0000_0043)
        let result = validate(interlaced, extra: [interlaced])
        #expect(result.warnings.contains { $0.contains("interlaced") })
    }

    @Test("The clean 200% HiDPI mode passes with only the workspace note")
    func clean200() {
        let result = validate(asus.mode(80))
        #expect(result.isValid)
        #expect(result.errors.isEmpty)
        #expect(!result.requiresRefreshConfirmation)
        #expect(result.warnings == ["Workspace shrinks to 25% of the native desktop area."])
    }

    @Test("Without a known native size, panel-dependent checks are skipped")
    func unknownNative() {
        let result = validate(asus.mode(91), native: .some(nil))
        #expect(result.isValid)
        #expect(!result.warnings.contains { $0.contains("panel") || $0.contains("scaled up") || $0.contains("Workspace") })
    }

    @Test("Without a current mode, refresh and already-active checks are skipped")
    func noCurrentMode() {
        let result = validate(asus.mode(119), current: .some(nil))
        #expect(result.isValid)
        #expect(!result.requiresRefreshConfirmation)
        #expect(!result.warnings.contains { $0.contains("refresh") })
    }
}

@Suite("Display mode lists")
struct DisplayModeListTests {
    let asus = Fixtures.asus

    @Test("Deduplication prefers the default-flagged entry over a lower mode ID")
    func dedupePrefersDefault() {
        let plain = asus.mode(115)
        let flagged = asus.mode(116)
        #expect(plain.signature == flagged.signature)
        #expect(DisplayModeService.deduplicated([plain, flagged]).map(\.modeID) == [116])
        #expect(DisplayModeService.deduplicated([flagged, plain]).map(\.modeID) == [116])
    }

    @Test("Deduplication falls back to the lowest mode ID")
    func dedupeLowestID() {
        let a = makeMode(50, 1920, 1080, 1920, 1080, 60, RawFlags.plain)
        let b = makeMode(40, 1920, 1080, 1920, 1080, 60, RawFlags.plain)
        #expect(DisplayModeService.deduplicated([a, b]).map(\.modeID) == [40])
    }

    @Test("Desktop modes exclude non-GUI, invalid and duplicate entries")
    func desktopModes() {
        let desktop = asus.desktopModes
        let ids = Set(desktop.map(\.modeID))
        #expect(!ids.contains(232))
        #expect(!ids.contains(115))
        #expect(ids.contains(116))
        #expect(desktop.count == asus.modes.count - 2)
        #expect(Set(desktop.map(\.signature)).count == desktop.count)
    }

    @Test("Sorting: largest logical first, 1× before HiDPI, highest refresh first")
    func sorting() {
        let desktop = asus.desktopModes
        #expect(desktop.first?.modeID == 116)
        #expect(desktop.last?.modeID == 97)
        let small = desktop.filter { $0.logical == PixelSize(width: 1720, height: 720) }.map(\.modeID)
        #expect(small == [74, 81, 83, 72, 76, 78, 80, 82])
    }

    @Test("Native resolution is the largest native-flagged mode, measured")
    func nativeResolution() {
        let fact = DisplayModeService.nativeResolution(from: asus.modes)
        #expect(fact.value == PixelSize(width: 3440, height: 1440))
        #expect(fact.provenance == .measured)
        #expect(DisplayModeService.nativeResolution(from: Fixtures.msi.modes).value == PixelSize(width: 1920, height: 1080))
    }

    @Test("Mode flags decode to names and hex")
    func flags() {
        let flags = DisplayModeFlags(rawValue: RawFlags.nativeDefault)
        #expect(flags.names == ["valid", "safe", "default", "native"])
        #expect(flags.hexDescription == "0x02000007")
        #expect(asus.mode(80).hasNativeFlag)
        #expect(!asus.mode(110).hasNativeFlag)
    }

    @Test("Mode summary and scale factor")
    func summary() {
        #expect(asus.mode(80).summary == "1720 × 720 HiDPI @ 120 Hz")
        #expect(asus.mode(80).scaleFactor == 2)
        #expect(asus.mode(119).summary == "3440 × 1440 @ 120 Hz")
        #expect(!asus.mode(119).isHiDPI)
    }
}

@MainActor
@Suite("Mode service and change plan (fake hardware)")
struct ModeServiceTests {
    @Test("DisplayModeService reads modes through the hardware boundary")
    func service() {
        let fake = FakeDisplayHardware()
        let service = DisplayModeService(hardware: fake)
        #expect(service.currentMode(for: 3)?.modeID == 119)
        #expect(service.allModes(for: 3).count == Fixtures.asus.modes.count)
        #expect(service.desktopModes(for: 3).count == Fixtures.asus.desktopModes.count)
        #expect(service.mode(withID: 80, for: 3)?.summary == "1720 × 720 HiDPI @ 120 Hz")
        #expect(service.mode(matching: Fixtures.asus.mode(115).signature, for: 3)?.modeID == 116)
        #expect(service.allModes(for: 42).isEmpty)
    }

    @Test("The change plan shows before/after for the 200% switch")
    func plan() throws {
        let fake = FakeDisplayHardware()
        let modes = DisplayModeService(hardware: fake)
        let configuration = DisplayConfigurationService(hardware: fake, modes: modes)
        let display = try #require(DisplayDiscoveryService(hardware: fake, modes: modes).display(withID: 3))
        let plan = configuration.plan(for: display, target: Fixtures.asus.mode(80))

        #expect(plan.validation.isValid)
        #expect(plan.refresh == .unchanged(120))
        let rows = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.label, $0) })
        #expect(rows["Interface size"]?.before == "100%")
        #expect(rows["Interface size"]?.after == "200%")
        #expect(rows["Rendered at"]?.after == "3440 × 1440")
        #expect(rows["Physical output"]?.changed == false)
        #expect(rows["Physical output"]?.after == "3440 × 1440 (native)")
        #expect(rows["Text rendering"]?.after == RenderingPath.nativeHiDPI.label)
        #expect(rows["Refresh rate"]?.changed == false)
        #expect(rows["Aspect ratio"]?.after == "21:9")
        #expect(fake.applyCalls.isEmpty)
    }
}
