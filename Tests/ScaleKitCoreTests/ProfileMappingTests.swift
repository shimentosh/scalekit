import Foundation
import Testing
@testable import ScaleKitCore

@Suite("Scaling profile mapping")
struct ProfileMappingTests {
    let asus = Fixtures.asus
    let uhd = Fixtures.uhd

    private func evaluation(
        _ percent: Int, _ fixture: MonitorFixture = Fixtures.asus,
        referenceRefresh: Double? = nil, verified: Set<ModeSignature> = []
    ) -> ProfileEvaluation {
        ScalingProfileMapper.evaluate(
            target: ScalingTarget(percent: percent), modes: fixture.desktopModes,
            context: fixture.context(referenceRefresh: referenceRefresh, verified: verified))
    }

    // MARK: ASUS VG34WQML5A

    @Test("ASUS 100% is Verified: the current 3440×1440 @ 120 Hz mode")
    func asus100() throws {
        let result = evaluation(100)
        #expect(result.status == .verified)
        #expect(result.isCurrent)
        let selection = try #require(result.selection)
        #expect(selection.mode.modeID == 119)
        #expect(selection.renderingPath == .native1x)
        #expect(selection.isClean)
        #expect(result.alternatives.isEmpty)
    }

    @Test("ASUS 200% is Available: 1720×720 HiDPI @ 120 Hz rendered at native resolution")
    func asus200() throws {
        let result = evaluation(200)
        #expect(result.status == .available)
        #expect(!result.isCurrent)
        let selection = try #require(result.selection)
        #expect(selection.mode.modeID == 80)
        #expect(selection.mode.summary == "1720 × 720 HiDPI @ 120 Hz")
        #expect(selection.renderingPath == .nativeHiDPI)
        #expect(selection.outputIsNative)
        #expect(selection.physicalOutput.value == PixelSize(width: 3440, height: 1440))
        #expect(selection.refresh == .unchanged(120))
        #expect(result.explanation.contains("not yet applied and confirmed"))
    }

    @Test("ASUS 200% becomes Verified once its signature has been verified on this Mac")
    func asus200Verified() {
        let result = evaluation(200, verified: [asus.mode(80).signature])
        #expect(result.status == .verified)
        #expect(result.selection?.mode.modeID == 80)
        #expect(result.selection?.isVerified == true)
        #expect(!result.explanation.contains("not yet applied"))
    }

    @Test("ASUS 125/150/175% are Unsupported with only 21:9 alternatives", arguments: [125, 150, 175])
    func asusIntermediateUnsupported(percent: Int) {
        let result = evaluation(percent)
        #expect(result.status == .unsupported)
        #expect(result.selection == nil)
        #expect(!result.isCurrent)
        #expect(!result.alternatives.isEmpty)
        #expect(result.alternatives.count <= 3)
        for alternative in result.alternatives {
            #expect(alternative.aspectMatchesNative)
            #expect(alternative.mode.logical.aspectLabel == "21:9")
        }
        let shapes = Set(result.alternatives.map { "\($0.mode.logical)|\($0.mode.pixels)" })
        #expect(shapes.count == result.alternatives.count, "one alternative per resolution")
        #expect(result.explanation.contains("macOS offers no mode"))
        #expect(result.explanation.contains("Closest option"))
    }

    @Test("ASUS 150% lists 2048×858 only as an alternative, with its trade-offs")
    func lowerResolutionIsOnlyAnAlternative() throws {
        let result = evaluation(150)
        #expect(result.alternatives.map(\.mode.modeID) == [80, 119, 110])
        let lowRes = try #require(result.alternatives.first { $0.mode.logical == PixelSize(width: 2048, height: 858) })
        #expect(lowRes.renderingPath == .upscaled1x)
        #expect(!lowRes.isClean)
        #expect(lowRes.tradeOffs.contains { $0.contains("scaled up") })
        #expect(lowRes.tradeOffs.contains { $0.contains("does not mark this mode as native output") })
    }

    @Test("No interface size 100…200% ever auto-selects a lower-resolution or unclean mode")
    func neverSelectsUnclean() {
        let context = asus.context()
        for percent in 100...200 {
            let result = ScalingProfileMapper.evaluate(
                target: ScalingTarget(percent: percent), modes: asus.desktopModes, context: context)
            guard let selection = result.selection else {
                #expect(result.status == .unsupported)
                continue
            }
            #expect(selection.isClean, "\(percent)% selected \(selection.mode.summary)")
            #expect(selection.mode.pixels == asus.native, "\(percent)% selected \(selection.mode.summary)")
            #expect(selection.mode.logical != PixelSize(width: 2048, height: 858))
            #expect([100, 200].contains(selection.uiPercent))
        }
    }

    @Test("Evaluating the standard targets returns 100, 125, 150, 175, 200 in order")
    func standardTargets() {
        let results = asus.evaluations()
        #expect(results.map(\.target.percent) == [100, 125, 150, 175, 200])
        #expect(results.map(\.status) == [.verified, .unsupported, .unsupported, .unsupported, .available])
    }

    // MARK: Synthetic 4K

    @Test("4K: 125%, 150% and 200% map to clean modes via HiDPI; 175% has none")
    func uhdProfiles() throws {
        let results = uhd.evaluations()
        let byPercent = Dictionary(uniqueKeysWithValues: results.map { ($0.target.percent, $0) })

        #expect(byPercent[100]?.status == .verified)
        #expect(byPercent[100]?.selection?.mode.modeID == 1)

        let p125 = try #require(byPercent[125]?.selection)
        #expect(byPercent[125]?.status == .available)
        #expect(p125.mode.modeID == 4)
        #expect(p125.renderingPath == .supersampledHiDPI)
        #expect(p125.tradeOffs.contains { $0.contains("downsampled") })

        let p150 = try #require(byPercent[150]?.selection)
        #expect(byPercent[150]?.status == .available)
        #expect(p150.mode.modeID == 3)
        #expect(p150.renderingPath == .supersampledHiDPI)

        let p200 = try #require(byPercent[200]?.selection)
        #expect(byPercent[200]?.status == .available)
        #expect(p200.mode.modeID == 2)
        #expect(p200.renderingPath == .nativeHiDPI)

        #expect(byPercent[175]?.status == .unsupported)
        #expect(byPercent[175]?.selection == nil)
    }

    // MARK: Refresh preference

    @Test("Exact reference refresh wins over higher and lower rates", arguments: [
        (120, 80), (180, 78), (240, 76), (250, 72), (60, 82),
    ] as [(Double, Int32)])
    func exactRefreshPreferred(reference: Double, expectedID: Int32) {
        #expect(evaluation(200, referenceRefresh: reference).selection?.mode.modeID == expectedID)
    }

    @Test("Without an exact match, the lowest higher rate is preferred")
    func lowestHigherRefresh() {
        // 100 Hz is not offered: 120 Hz is the closest rate above it.
        let result = evaluation(200, referenceRefresh: 100)
        #expect(result.selection?.mode.modeID == 80)
        #expect(result.selection?.refresh.isReduction == false)
    }

    @Test("Without a higher rate, the highest lower rate is chosen and the drop is explained")
    func highestLowerRefresh() {
        let result = evaluation(200, referenceRefresh: 300)
        #expect(result.selection?.mode.modeID == 72)
        #expect(result.selection?.refresh.isReduction == true)
        #expect(result.explanation.contains("Only available at 250 Hz."))
    }

    @Test("Refresh tolerance treats 119.88 Hz as 120 Hz")
    func refreshTolerance() {
        #expect(evaluation(200, referenceRefresh: 119.88).selection?.mode.modeID == 80)
    }

    @Test("Reference refresh: preferred when offered, otherwise the current rate")
    func referenceRefresh() {
        let modes = asus.desktopModes
        let current = asus.currentMode
        #expect(EvaluationContext.referenceRefresh(preferred: 120, modes: modes, current: current) == 120)
        #expect(EvaluationContext.referenceRefresh(preferred: 240, modes: modes, current: current) == 240)
        #expect(EvaluationContext.referenceRefresh(preferred: 144, modes: modes, current: current) == 120)
        #expect(EvaluationContext.referenceRefresh(preferred: 0, modes: modes, current: current) == 120)
        #expect(EvaluationContext.referenceRefresh(preferred: 144, modes: modes, current: nil) == 144)
        #expect(EvaluationContext.referenceRefresh(preferred: 100, modes: Fixtures.msi.desktopModes, current: Fixtures.msi.currentMode) == 100)
    }

    @Test("Current UI scale is native width ÷ logical width")
    func currentUIScale() {
        #expect(ScalingProfileMapper.currentUIScale(context: asus.context()) == 1.0)
        #expect(ScalingProfileMapper.currentUIScale(context: asus.context(currentModeID: 80)) == 2.0)
        let noCurrent = EvaluationContext(native: asus.native, currentMode: nil, referenceRefresh: 120, verifiedSignatures: [])
        #expect(ScalingProfileMapper.currentUIScale(context: noCurrent) == nil)
    }

    @Test("Ideal logical sizes for each target on the ASUS panel")
    func idealSizes() {
        let native = asus.native
        #expect(ScalingTarget(percent: 100).idealLogicalSize(native: native) == native)
        #expect(ScalingTarget(percent: 125).idealLogicalSize(native: native) == PixelSize(width: 2752, height: 1152))
        #expect(ScalingTarget(percent: 150).idealLogicalSize(native: native) == PixelSize(width: 2293, height: 960))
        #expect(ScalingTarget(percent: 200).idealLogicalSize(native: native) == PixelSize(width: 1720, height: 720))
        #expect(ScalingTarget.standard.map(\.description) == ["100%", "125%", "150%", "175%", "200%"])
        #expect(ScalingTarget(percent: 125) < ScalingTarget(percent: 150))
    }
}

@MainActor
@Suite("Scaling profile service (fake hardware)", .serialized)
struct ScalingProfileServiceTests {
    @Test("Evaluations through the service match the pure mapper")
    func evaluationsMatchMapper() throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let display = try #require(harness.display())
        let viaService = harness.services.profiles.evaluations(for: display, preferredRefresh: 120)
        #expect(viaService == Fixtures.asus.evaluations(referenceRefresh: 120))
    }

    @Test("A stored verification record promotes 200% to Verified")
    func storedVerification() throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let display = try #require(harness.display())
        harness.services.verifications.record(VerificationRecord(
            displayKey: display.key, displayName: display.displayName, signature: Fixtures.asus.mode(80).signature,
            verifiedAt: Fixtures.fixedDate, osVersion: "macOS 27.0", hardwareModel: "Mac16,10",
            observedScale: 2, method: "test"))
        let p200 = try #require(harness.services.profiles.evaluations(for: display, preferredRefresh: 120).last)
        #expect(p200.target.percent == 200)
        #expect(p200.status == .verified)
    }

    @Test("Preferred refresh that the display does not offer falls back to the current rate")
    func contextFallsBack() throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let msi = try #require(harness.display(Fixtures.msi.displayID))
        let context = try #require(harness.services.profiles.context(for: msi, preferredRefresh: 120))
        #expect(context.referenceRefresh == 100)
        #expect(context.native == PixelSize(width: 1920, height: 1080))
    }
}
