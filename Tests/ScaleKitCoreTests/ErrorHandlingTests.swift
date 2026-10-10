import Foundation
import Testing
@testable import ScaleKitCore

@Suite("Error descriptions")
struct DisplayHardwareErrorTests {
    @Test("Each error explains itself")
    func descriptions() {
        #expect(DisplayHardwareError.displayNotFound(3).errorDescription == "Display 3 is no longer connected.")
        #expect(DisplayHardwareError.modeNotFound(displayID: 3, modeID: 80).errorDescription
            == "macOS no longer offers mode 80 for display 3.")
        #expect(DisplayHardwareError.coreGraphics(operation: "CGBeginDisplayConfiguration", code: 1001).errorDescription
            == "CGBeginDisplayConfiguration failed with CoreGraphics error 1001 (illegal argument).")
        #expect(DisplayHardwareError.coreGraphics(operation: "X", code: 4242).errorDescription
            == "X failed with CoreGraphics error 4242 (unknown).")
    }

    @Test("localizedDescription uses the explanation")
    func localized() {
        let error: any Error = DisplayHardwareError.displayNotFound(1)
        #expect(error.localizedDescription == "Display 1 is no longer connected.")
    }

    @Test("CoreGraphics error codes", arguments: [
        (1000, "failure"), (1001, "illegal argument"), (1002, "invalid connection"), (1003, "invalid context"),
        (1004, "cannot complete"), (1006, "not implemented"), (1007, "range check"), (1008, "type check"),
        (1010, "invalid operation"), (1011, "none available"), (0, "unknown"), (1005, "unknown"),
    ] as [(Int32, String)])
    func codes(code: Int32, meaning: String) {
        #expect(DisplayHardwareError.describe(code) == meaning)
    }
}

@Suite("Verification evaluator")
struct VerificationEvaluatorTests {
    let asus = Fixtures.asus
    var requested: DisplayModeInfo { asus.mode(80) }

    @Test("No observed mode: failed")
    func noObserved() {
        let result = VerificationEvaluator.evaluate(requested: requested, observed: nil, screen: asus.screen(for: requested))
        #expect(result.level == .failed)
        #expect(result.notes.first?.contains("no active mode") == true)
    }

    @Test("A different mode: failed")
    func mismatch() {
        let result = VerificationEvaluator.evaluate(
            requested: requested, observed: asus.mode(119), screen: asus.screen(for: asus.mode(119)))
        #expect(result.level == .failed)
        #expect(result.notes.first?.contains("instead of the requested") == true)
    }

    @Test("Same look but different refresh: failed")
    func refreshMismatch() {
        let result = VerificationEvaluator.evaluate(requested: requested, observed: asus.mode(82), screen: nil)
        #expect(result.level == .failed)
    }

    @Test("Matching mode without a screen: partial")
    func noScreen() {
        let result = VerificationEvaluator.evaluate(requested: requested, observed: requested, screen: nil)
        #expect(result.level == .partial)
        #expect(result.notes.contains { $0.contains("not cross-checked") })
    }

    @Test("Matching mode and AppKit agrees: verified")
    func agree() {
        let result = VerificationEvaluator.evaluate(requested: requested, observed: requested, screen: asus.screen(for: requested))
        #expect(result.level == .verified)
        #expect(result.notes.last == "AppKit reports 1720 × 720 points at 2× backing scale.")
    }

    @Test("A renumbered but identical mode still verifies")
    func renumbered() {
        let renumbered = DisplayModeInfo(
            modeID: 4000, logical: requested.logical, pixels: requested.pixels, refreshRate: requested.refreshRate,
            flags: requested.flags, isUsableForDesktopGUI: true)
        #expect(VerificationEvaluator.evaluate(requested: requested, observed: renumbered, screen: asus.screen(for: requested)).level == .verified)
    }

    @Test("AppKit disagrees on scale or size: partial")
    func disagree() {
        var wrongScale = asus.screen(for: requested)
        wrongScale.backingScaleFactor = 1
        #expect(VerificationEvaluator.evaluate(requested: requested, observed: requested, screen: wrongScale).level == .partial)

        var wrongSize = asus.screen(for: requested)
        wrongSize.frame = DisplayBounds(x: 0, y: 0, width: 3440, height: 1440)
        let result = VerificationEvaluator.evaluate(requested: requested, observed: requested, screen: wrongSize)
        #expect(result.level == .partial)
        #expect(result.notes.last?.contains("expected 1720 × 720 at 2×") == true)
    }
}

@MainActor
@Suite("Display configuration service (fake hardware)", .serialized)
struct DisplayConfigurationServiceTests {
    private func makeService(_ fake: FakeDisplayHardware) -> DisplayConfigurationService {
        let service = DisplayConfigurationService(hardware: fake, modes: DisplayModeService(hardware: fake))
        service.verificationTimeout = .milliseconds(300)
        service.pollInterval = .milliseconds(20)
        return service
    }

    @Test("Apply rethrows hardware errors unchanged")
    func applyThrows() async {
        let fake = FakeDisplayHardware()
        fake.applyError = DisplayHardwareError.coreGraphics(operation: "CGCompleteDisplayConfiguration", code: 1004)
        let service = makeService(fake)
        await #expect(throws: DisplayHardwareError.coreGraphics(operation: "CGCompleteDisplayConfiguration", code: 1004)) {
            _ = try await service.apply(Fixtures.asus.mode(80), to: 3, scope: .appOnly)
        }
        #expect(fake.currentModeID(on: 3) == 119)
    }

    @Test("Apply to a disconnected display throws displayNotFound")
    func displayGone() async {
        let fake = FakeDisplayHardware()
        fake.disconnect(3)
        let service = makeService(fake)
        await #expect(throws: DisplayHardwareError.displayNotFound(3)) {
            _ = try await service.apply(Fixtures.asus.mode(80), to: 3, scope: .appOnly)
        }
    }

    @Test("Apply then verify: verified with measured scale and size")
    func applyVerified() async throws {
        let fake = FakeDisplayHardware()
        let service = makeService(fake)
        let result = try await service.apply(Fixtures.asus.mode(80), to: 3, scope: .appOnly)
        #expect(result.level == .verified)
        #expect(result.modeMatches)
        #expect(result.screenScale == .measured(2, source: "NSScreen.backingScaleFactor"))
        #expect(result.screenSize.value == PixelSize(width: 1720, height: 720))
        #expect(result.secondary.provenance == .unavailable)
        #expect(result.elapsedSeconds >= 0)
        #expect(fake.applyCalls == [.init(modeID: 80, displayID: 3, scope: .appOnly)])
    }

    @Test("A mode that never takes effect fails verification after the timeout")
    func neverApplies() async throws {
        let fake = FakeDisplayHardware()
        fake.ignoresApply = true
        let service = makeService(fake)
        let result = try await service.apply(Fixtures.asus.mode(80), to: 3, scope: .appOnly)
        #expect(result.level == .failed)
        #expect(!result.modeMatches)
        #expect(result.observed?.modeID == 119)
        #expect(result.elapsedSeconds >= 0.25)
    }

    @Test("No AppKit screen: partial verification")
    func noScreen() async throws {
        let fake = FakeDisplayHardware()
        fake.hiddenScreens = [3]
        let service = makeService(fake)
        let result = try await service.apply(Fixtures.asus.mode(80), to: 3, scope: .appOnly)
        #expect(result.level == .partial)
        #expect(result.modeMatches)
        #expect(result.screenScale.provenance == .unavailable)
    }
}
