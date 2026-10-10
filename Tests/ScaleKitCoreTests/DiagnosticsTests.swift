import Foundation
import Testing
@testable import ScaleKitCore

@Suite("Outcome assessment")
struct OutcomeAssessorTests {
    private func outcomes(_ fixture: MonitorFixture, currentModeID: Int32? = nil, referenceRefresh: Double = 120) -> [String: OutcomeAssessment] {
        let display = fixture.info(currentModeID: currentModeID)
        let context = fixture.context(referenceRefresh: referenceRefresh, currentModeID: currentModeID)
        let profiles = ScalingProfileMapper.evaluate(modes: fixture.desktopModes, context: context)
        let results = OutcomeAssessor.assess(
            display: display, modes: fixture.desktopModes, profiles: profiles, referenceRefresh: referenceRefresh)
        return Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
    }

    @Test("ASUS at 3440×1440 @ 120 Hz")
    func asusNow() {
        let results = outcomes(Fixtures.asus)
        #expect(results.count == 7)
        #expect(results["native"]?.status == .achievedNow)
        #expect(results["refresh"]?.status == .achievedNow)
        #expect(results["aspect"]?.status == .achievedNow)
        #expect(results["hidpi"]?.status == .achievable)
        #expect(results["larger"]?.status == .achievable)
        #expect(results["larger"]?.detail == "Available at: 200%.")
        #expect(results["intermediate"]?.status == .notAchievable)
        #expect(results["intermediate"]?.detail.contains("Public APIs cannot create them") == true)
        #expect(results["combined"]?.status == .achievable)
        #expect(results["combined"]?.detail.contains("200% (looks like 1720 × 720)") == true)
    }

    @Test("ASUS after switching to 1720×720 HiDPI @ 120 Hz")
    func asusAt200() {
        let results = outcomes(Fixtures.asus, currentModeID: 80)
        #expect(results["native"]?.status == .achievedNow)
        #expect(results["hidpi"]?.status == .achievedNow)
        #expect(results["larger"]?.status == .achievedNow)
        #expect(results["combined"]?.status == .achievedNow)
        #expect(results["intermediate"]?.status == .notAchievable)
    }

    @Test("ASUS on a non-native mode")
    func asusNonNative() {
        let results = outcomes(Fixtures.asus, currentModeID: 91)
        #expect(results["native"]?.status == .achievable)
        #expect(results["aspect"]?.status == .achievable)
        #expect(results["refresh"]?.status == .achievable)
    }

    @Test("4K: intermediate sizes are partially achievable")
    func uhd() {
        let results = outcomes(Fixtures.uhd, referenceRefresh: 60)
        #expect(results["intermediate"]?.status == .partiallyAchievable)
        #expect(results["intermediate"]?.detail == "Supported: 125%, 150%.")
        #expect(results["larger"]?.detail == "Available at: 125%, 150%, 200%.")
    }

    @Test("Unknown native resolution gives a single unknown outcome")
    func unknownNative() {
        let display = Fixtures.noModes.info()
        let results = OutcomeAssessor.assess(display: display, modes: [], profiles: [], referenceRefresh: 120)
        #expect(results.map(\.status) == [.unknown])
    }
}

@MainActor
@Suite("Diagnostic report", .serialized)
struct DiagnosticReportTests {
    @Test("Markdown contains every key section")
    func markdown() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let events = [RecordedDisplayEvent(date: Fixtures.fixedDate, description: "System will sleep")]
        let report = await harness.services.diagnostics.makeReport(
            preferredRefresh: 120, desired: ScalingTarget(percent: 150), events: events, includeSystemProfiler: false)

        #expect(report.displays.map(\.info.id) == [3, 1])
        #expect(report.targetMonitor?.displayID == 3)
        #expect(report.targetMonitor?.confidence == .high)
        let asusSection = try #require(report.displays.first)
        #expect(asusSection.referenceRefresh == 120)
        #expect(asusSection.totalModeCount == Fixtures.asus.modes.count)
        #expect(asusSection.desktopModes.count == Fixtures.asus.desktopModes.count)
        #expect(asusSection.systemProfiler.provenance == .unavailable)
        #expect(asusSection.recommendation?.assessment?.mode.modeID == 80)

        let markdown = DiagnosticMarkdown.render(report)
        for section in [
            "# ScaleKit Diagnostic Report",
            "**Target monitor:** ASUS TUF Gaming VG34WQML5A → display 3, identification confidence **High**",
            "## Display 3 — VG34WQML5A (main)",
            "## Display 1 — MSI MP223",
            "### Target outcomes",
            "### Facts",
            "### HiDPI",
            "### Scaling profiles (reference refresh 120 Hz)",
            "### Recommendation for a 150% target",
            "### Desktop modes (26 unique of 28 reported)",
            "## Verification records",
            "No mode has been applied and read back by ScaleKit on this Mac yet.",
            "## Display events observed",
            "System will sleep",
            "| Native resolution | 3440 × 1440 | M |",
            "| Physical output | 3440 × 1440 px | I |",
            "| 100% (current) | **Verified** | 3440 × 1440 @ 120 Hz (ID 119)",
            "| 200% | **Available** | 1720 × 720 HiDPI @ 120 Hz (ID 80)",
            "| 150% | **Unsupported** |",
        ] {
            #expect(markdown.contains(section), "Missing: \(section)")
        }
    }

    @Test("Without the ASUS, the report says so")
    func markdownWithoutTarget() async throws {
        let harness = try ServicesHarness(monitors: [Fixtures.msi])
        defer { harness.cleanup() }
        let report = await harness.services.diagnostics.makeReport(preferredRefresh: 120, includeSystemProfiler: false)
        let markdown = DiagnosticMarkdown.render(report)
        #expect(markdown.contains("ASUS VG34WQML5A was not found"))
        #expect(!markdown.contains("## Display events observed"))
    }

    @Test("Verification records appear in the report")
    func markdownWithVerification() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        harness.services.verifications.record(VerificationRecord(
            displayKey: Fixtures.asus.key, displayName: "VG34WQML5A", signature: Fixtures.asus.mode(80).signature,
            verifiedAt: Fixtures.fixedDate, osVersion: "macOS 27.0", hardwareModel: "Mac16,10",
            observedScale: 2, method: "test method"))
        let report = await harness.services.diagnostics.makeReport(preferredRefresh: 120, includeSystemProfiler: false)
        let markdown = DiagnosticMarkdown.render(report)
        #expect(markdown.contains("| VG34WQML5A | 1720 × 720 HiDPI (3440 × 1440) @ 120 Hz |"))
        #expect(markdown.contains("| 200% | **Verified** |"))
    }

    @Test("Reports are written as Markdown and decodable JSON")
    func write() async throws {
        let harness = try ServicesHarness()
        defer { harness.cleanup() }
        let report = await harness.services.diagnostics.makeReport(preferredRefresh: 120, includeSystemProfiler: false)
        let files = try DiagnosticsService.write(report, to: harness.paths.reportsDirectory, basename: "test-report")
        #expect(files.markdown.lastPathComponent == "test-report.md")
        #expect(FileManager.default.fileExists(atPath: files.markdown.path))
        let decoded = try JSONCoding.decoder().decode(DiagnosticReport.self, from: Data(contentsOf: files.json))
        #expect(decoded.displays.count == 2)
        #expect(decoded.displays.first?.profiles == report.displays.first?.profiles)
        #expect(decoded.scaleKitVersion == ScaleKitInfo.version)
    }
}

@Suite("System profiler parsing")
struct SystemProfilerTests {
    @Test("Parses the display entry")
    func parse() throws {
        let json = #"{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_name":"VG34WQML5A","_spdisplays_displayID":"3","_spdisplays_pixels":"3440 x 1440","_spdisplays_resolution":"3440 x 1440 @ 120.00Hz"}]}]}"#
        let displays = try #require(SystemProfilerProbe.parse(Data(json.utf8)))
        #expect(displays == [SystemProfilerDisplay(
            displayID: 3, name: "VG34WQML5A", pixels: "3440 x 1440", resolution: "3440 x 1440 @ 120.00Hz")])
        #expect(displays.first?.summary == "pixels 3440 x 1440 · UI looks like 3440 x 1440 @ 120.00Hz")
    }

    @Test("Multiple GPUs and displays are flattened; missing fields are nil")
    func multiple() throws {
        let json = #"{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_name":"A","_spdisplays_displayID":"1"},{"_name":"B","_spdisplays_displayID":"not-a-number"}]},{"_name":"GPU without displays"}]}"#
        let displays = try #require(SystemProfilerProbe.parse(Data(json.utf8)))
        #expect(displays.map(\.name) == ["A", "B"])
        #expect(displays.map(\.displayID) == [1, nil])
        #expect(displays.first?.summary == "pixels ? · UI looks like ?")
    }

    @Test("Malformed output yields nil", arguments: ["", "not json", "[]", #"{"other":[]}"#])
    func malformed(text: String) {
        #expect(SystemProfilerProbe.parse(Data(text.utf8)) == nil)
    }
}

@MainActor
@Suite("Display events")
struct DisplayEventTests {
    @Test("Change-set flags decode to names")
    func names() {
        let changes = DisplayChangeSet(rawValue: (1 << 3) | (1 << 4))
        #expect(changes == [.setMode, .added])
        #expect(changes.names == ["setMode", "added"])
        #expect(!changes.isPreflight)
        #expect(DisplayChangeSet.beginConfiguration.isPreflight)
        #expect(DisplayChangeSet([.removed, .disabled, .desktopShapeChanged]).names == ["removed", "disabled", "desktopShapeChanged"])
        #expect(DisplayChangeSet(rawValue: 0).names.isEmpty)
    }

    @Test("Event descriptions")
    func descriptions() {
        #expect(DisplayEvent.reconfigured(displayID: 3, changes: [.setMode]).description == "Display 3: setMode")
        #expect(DisplayEvent.systemWillSleep.description == "System will sleep")
        #expect(DisplayEvent.screenParametersChanged.description == "Screen parameters changed")
    }

    @Test("Injected events reach handlers and are recorded without starting system monitoring")
    func emit() {
        let monitor = DisplayEventMonitor()
        let received = Box<[DisplayEvent]>([])
        let id = monitor.addHandler { received.value.append($0) }
        monitor.emit(.systemWillSleep)
        monitor.emit(.reconfigured(displayID: 3, changes: [.setMode]))
        #expect(received.value == [.systemWillSleep, .reconfigured(displayID: 3, changes: [.setMode])])
        #expect(monitor.recentEvents.map(\.description) == ["System will sleep", "Display 3: setMode"])

        monitor.removeHandler(id)
        monitor.emit(.systemDidWake)
        #expect(received.value.count == 2)
        #expect(monitor.recentEvents.count == 3)
    }

    @Test("The recent-event log is capped")
    func cap() {
        let monitor = DisplayEventMonitor()
        monitor.recentEventLimit = 3
        for _ in 0..<5 { monitor.emit(.screensDidWake) }
        monitor.emit(.systemWillPowerOff)
        #expect(monitor.recentEvents.count == 3)
        #expect(monitor.recentEvents.last?.description == "System will power off")
    }
}
