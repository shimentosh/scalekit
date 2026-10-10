import Foundation
import Testing
@testable import ScaleKitCore

@Suite("Unsupported configurations")
struct UnsupportedConfigurationTests {
    @Test("No native flag at all: native resolution is inferred from the largest 1× mode")
    func inferredNative() {
        let fact = DisplayModeService.nativeResolution(from: Fixtures.noNativeFlag.modes)
        #expect(fact.value == PixelSize(width: 1920, height: 1080))
        #expect(fact.provenance == .inferred)
        #expect(fact.source.contains("No mode carries the native flag"))
    }

    @Test("No native flag: physical output is unavailable and no profile auto-selects an unflagged mode")
    func noNativeFlagProfiles() {
        let fixture = Fixtures.noNativeFlag
        let info = fixture.info()
        #expect(info.nativeResolution.provenance == .inferred)
        #expect(info.physicalOutput.provenance == .unavailable)
        for evaluation in fixture.evaluations() {
            #expect(evaluation.selection == nil, "\(evaluation.target)")
            #expect(evaluation.status == .unsupported)
        }
    }

    @Test("No modes at all: native resolution is unavailable")
    func noModes() {
        let fact = DisplayModeService.nativeResolution(from: [])
        #expect(fact.value == nil)
        #expect(fact.provenance == .unavailable)
        let info = Fixtures.noModes.info()
        #expect(info.nativeResolution.provenance == .unavailable)
        #expect(info.currentMode == nil)
        #expect(info.pixelDensity.provenance == .unavailable)
    }

    @Test("Only HiDPI modes and no native flag: native resolution cannot be inferred")
    func hiDPIOnlyUnflagged() {
        let modes = [makeMode(1, 1280, 720, 2560, 1440, 60, RawFlags.plain)]
        #expect(DisplayModeService.nativeResolution(from: modes).provenance == .unavailable)
    }

    @Test("Validation against an unknown panel still blocks unoffered modes")
    func validationUnknownPanel() {
        let mode = makeMode(1, 1920, 1080, 1920, 1080, 60, RawFlags.plain)
        let result = ModeValidator.validate(mode, available: [], current: nil, native: nil)
        #expect(!result.isValid)
    }
}

@MainActor
@Suite("Unsupported configurations through the services", .serialized)
struct UnsupportedServiceTests {
    @Test("Profiles are Unknown when the native resolution is unknown")
    func unknownProfiles() throws {
        let harness = try ServicesHarness(monitors: [Fixtures.noModes])
        defer { harness.cleanup() }
        let display = try #require(harness.display(Fixtures.noModes.displayID))
        #expect(display.nativeResolution.value == nil)

        let profiles = harness.services.profiles
        let evaluations = profiles.evaluations(for: display, preferredRefresh: 120)
        #expect(evaluations.map(\.target) == ScalingTarget.standard)
        #expect(evaluations.allSatisfy { $0.status == .unknown && $0.selection == nil && $0.alternatives.isEmpty })
        #expect(profiles.context(for: display, preferredRefresh: 120) == nil)
        #expect(profiles.recommendation(
            for: display, desired: ScalingTarget(percent: 150), preferredRefresh: 120, evaluations: evaluations) == nil)
        #expect(profiles.assess(Fixtures.asus.mode(80), on: display, desired: ScalingTarget(percent: 200), preferredRefresh: 120) == nil)
    }

    @Test("Diagnostics still render for a display with no modes")
    func diagnosticsForModelessDisplay() async throws {
        let harness = try ServicesHarness(monitors: [Fixtures.noModes])
        defer { harness.cleanup() }
        let report = await harness.services.diagnostics.makeReport(preferredRefresh: 120, includeSystemProfiler: false)
        let section = try #require(report.displays.first)
        #expect(section.referenceRefresh == nil)
        #expect(section.recommendation == nil)
        #expect(section.outcomes.isEmpty)
        #expect(section.hiDPIStatus.confidence == .none)
        #expect(section.hiDPIAvailability.hiDPIModeCount == 0)
        let markdown = DiagnosticMarkdown.render(report)
        #expect(markdown.contains("| Native resolution | — | U |"))
        #expect(markdown.contains("| 150% | **Unknown** |"))
    }

    @Test("A trial on a display with an unflagged panel shows the unknown physical output")
    func planUnflagged() throws {
        let harness = try ServicesHarness(monitors: [Fixtures.noNativeFlag])
        defer { harness.cleanup() }
        let display = try #require(harness.display(Fixtures.noNativeFlag.displayID))
        let plan = harness.services.configuration.plan(for: display, target: Fixtures.noNativeFlag.mode(42))
        #expect(plan.validation.isValid)
        #expect(plan.validation.warnings.contains { $0.contains("native timing") })
        #expect(plan.rows.first { $0.label == "Physical output" }?.after == "Not reported")
    }
}
