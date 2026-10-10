import Foundation
import Testing
@testable import ScaleKitCore

@Suite("Profile recommendation")
struct RecommendationTests {
    let asus = Fixtures.asus

    private func recommend(
        _ percent: Int, fixture: MonitorFixture = Fixtures.asus, modes: [DisplayModeInfo]? = nil,
        referenceRefresh: Double? = nil
    ) -> Recommendation {
        let context = fixture.context(referenceRefresh: referenceRefresh)
        let modes = modes ?? fixture.desktopModes
        return RecommendationEngine.recommend(
            evaluations: ScalingProfileMapper.evaluate(modes: modes, context: context),
            modes: modes, desired: ScalingTarget(percent: percent), context: context)
    }

    @Test("ASUS, desired 150%: recommends 1720×720 HiDPI @ 120 Hz meeting every criterion")
    func asus150() throws {
        let recommendation = recommend(150, referenceRefresh: 120)
        let assessment = try #require(recommendation.assessment)
        #expect(assessment.mode.logical == PixelSize(width: 1720, height: 720))
        #expect(assessment.mode.isHiDPI)
        #expect(assessment.mode.refreshRate == 120)
        #expect(assessment.mode.modeID == 80)
        #expect(recommendation.meetsAllCriteria)
        #expect(recommendation.profile == ScalingTarget(percent: 200))
        #expect(recommendation.headline.contains("keeps native output"))
        #expect(recommendation.headline.hasPrefix("200% · 1720 × 720 HiDPI @ 120 Hz"))
        #expect(recommendation.reasons.count == 7)
    }

    @Test("The recommendation agrees with the profile selection at the reference refresh",
          arguments: [60.0, 120.0, 180.0, 240.0, 250.0])
    func recommendationMatchesProfileRefresh(reference: Double) throws {
        let recommendation = recommend(200, referenceRefresh: reference)
        let assessment = try #require(recommendation.assessment)
        #expect(RefreshRate.isSame(assessment.mode.refreshRate, reference))
        #expect(recommendation.profile == ScalingTarget(percent: 200))
    }

    @Test("ASUS, desired 100%: the current native mode is recommended")
    func asus100() {
        let recommendation = recommend(100, referenceRefresh: 120)
        #expect(recommendation.assessment?.mode.modeID == 119)
        #expect(recommendation.assessment?.isCurrent == true)
        #expect(recommendation.meetsAllCriteria)
        #expect(recommendation.profile == ScalingTarget(percent: 100))
    }

    @Test("Non-native upscaled modes never outrank a clean native mode of the same shape and refresh",
          arguments: 100...200)
    func nativeOutranksUpscaled(percent: Int) {
        let desired = ScalingTarget(percent: percent)
        for fixture in [Fixtures.asus, Fixtures.msi, Fixtures.uhd] {
            let context = fixture.context()
            let ranked = RecommendationEngine.rank(fixture.desktopModes, desired: desired, context: context)
            let position = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1.mode.modeID, $0) })
            let clean = ranked.filter(\.isClean)
            let upscaled = ranked.filter {
                !$0.outputIsNative && ($0.renderingPath == .upscaled1x || $0.renderingPath == .upscaledHiDPI)
            }
            #expect(!clean.isEmpty && !upscaled.isEmpty)
            for good in clean {
                for bad in upscaled
                where bad.mode.logical.hasSameAspect(as: good.mode.logical)
                    && RefreshRate.isSame(bad.mode.refreshRate, good.mode.refreshRate) {
                    #expect(
                        good.score.total > bad.score.total,
                        "\(fixture.name) \(desired): \(bad.mode.summary) (\(bad.score.total)) vs \(good.mode.summary) (\(good.score.total))")
                    #expect(position[good.mode.modeID]! < position[bad.mode.modeID]!)
                }
            }
        }
    }

    @Test("An unverified mode scores lower than the identical verified mode",
          arguments: [(Fixtures.asus, 80), (Fixtures.uhd, 3), (Fixtures.uhd, 4), (Fixtures.asus, 120)] as [(MonitorFixture, Int32)])
    func verificationRaisesScore(fixture: MonitorFixture, modeID: Int32) {
        let mode = fixture.mode(modeID)
        let desired = ScalingTarget(percent: 150)
        let unverified = RecommendationEngine.assess(mode, desired: desired, context: fixture.context())
        let verified = RecommendationEngine.assess(
            mode, desired: desired, context: fixture.context(verified: [mode.signature]))
        #expect(!unverified.isVerified)
        #expect(verified.isVerified)
        #expect(unverified.score.total < verified.score.total)
    }

    @Test("Score components sum to the total and the maximum is 100", arguments: [100, 125, 150, 175, 200])
    func scoreArithmetic(percent: Int) {
        for fixture in [Fixtures.asus, Fixtures.msi, Fixtures.uhd, Fixtures.noNativeFlag] {
            let context = fixture.context()
            for mode in fixture.modes {
                let score = RecommendationEngine.assess(mode, desired: ScalingTarget(percent: percent), context: context).score
                let sum = score.components.map(\.points).reduce(0, +)
                #expect(abs(score.total - sum) < 1e-9)
                #expect(score.maxTotal == 100)
                #expect(score.components.map(\.name) == [
                    "Readability", "Native output", "Sharpness", "Refresh rate", "Aspect ratio", "Stability", "Workspace",
                ])
                for component in score.components {
                    #expect(component.points >= 0, "\(component.name) for \(mode.summary)")
                    #expect(component.points <= component.maxPoints + 1e-9, "\(component.name) for \(mode.summary)")
                }
            }
        }
    }

    @Test("Weights are documented and total 100")
    func weights() {
        let total = RecommendationEngine.readabilityWeight + RecommendationEngine.nativeOutputWeight
            + RecommendationEngine.sharpnessWeight + RecommendationEngine.refreshWeight
            + RecommendationEngine.aspectWeight + RecommendationEngine.stabilityWeight
            + RecommendationEngine.workspaceWeight
        #expect(total == 100)
        // Native output plus best-case sharpness outweighs perfect readability.
        #expect(RecommendationEngine.nativeOutputWeight + RecommendationEngine.sharpnessWeight > RecommendationEngine.readabilityWeight)
    }

    @Test("Exact score breakdown of the 200% mode for a 150% target")
    func breakdown() {
        let assessment = RecommendationEngine.assess(
            asus.mode(80), desired: ScalingTarget(percent: 150), context: asus.context())
        let points = Dictionary(uniqueKeysWithValues: assessment.score.components.map { ($0.name, $0.points) })
        #expect(approximately(points["Readability"], 12.5))
        #expect(approximately(points["Native output"], 20))
        #expect(approximately(points["Sharpness"], 10))
        #expect(approximately(points["Refresh rate"], 15))
        #expect(approximately(points["Aspect ratio"], 10))
        #expect(approximately(points["Stability"], 8))
        #expect(approximately(points["Workspace"], 1.25))
        #expect(approximately(assessment.score.total, 76.75))
        #expect(assessment.uiPercent == 200)
    }

    @Test("Refresh drops are scored proportionally")
    func refreshScoring() {
        let context = asus.context(referenceRefresh: 120)
        let at60 = RecommendationEngine.assess(asus.mode(82), desired: ScalingTarget(percent: 200), context: context)
        let refresh = at60.score.components.first { $0.name == "Refresh rate" }
        #expect(approximately(refresh?.points, 7.5))
        #expect(at60.refresh.isReduction)
        #expect(at60.tradeOffs.contains("Refresh rate drops from 120 Hz to 60 Hz."))
    }

    @Test("When no clean mode exists, the best option does not claim to meet every criterion")
    func noCleanMode() {
        let unflagged = asus.desktopModes.filter { !$0.hasNativeFlag }
        let recommendation = recommend(150, modes: unflagged, referenceRefresh: 120)
        #expect(recommendation.assessment != nil)
        #expect(recommendation.assessment?.isClean == false)
        #expect(!recommendation.meetsAllCriteria)
        #expect(recommendation.profile == nil)
        #expect(recommendation.headline.hasPrefix("No mode meets every criterion for 150%"))
    }

    @Test("A clean mode at a reduced refresh rate does not meet every criterion")
    func reducedRefresh() {
        let sixtyHz = asus.desktopModes.filter { $0.refreshRate == 60 }
        let recommendation = recommend(200, modes: sixtyHz, referenceRefresh: 120)
        #expect(recommendation.assessment?.mode.modeID == 82)
        #expect(recommendation.assessment?.isClean == true)
        #expect(!recommendation.meetsAllCriteria)
    }

    @Test("No modes at all yields no assessment")
    func noModes() {
        let recommendation = RecommendationEngine.recommend(
            evaluations: [], modes: [], desired: ScalingTarget(percent: 150), context: asus.context())
        #expect(recommendation.assessment == nil)
        #expect(!recommendation.meetsAllCriteria)
        #expect(recommendation.headline == "No usable display modes were reported.")
    }

    @Test("Only aspect-correct modes are recommended when any exist")
    func aspectFilter() {
        for percent in stride(from: 100, through: 300, by: 10) {
            let recommendation = recommend(percent, referenceRefresh: 120)
            #expect(recommendation.assessment?.aspectMatchesNative == true, "\(percent)%")
        }
    }
}
