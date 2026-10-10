import Foundation

public enum ScaleKitInfo {
    public static let version = "0.1.0"
}

/// Whether one of the user's goals can be met on a display.
public struct OutcomeAssessment: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case achievedNow, achievable, partiallyAchievable, notAchievable, unknown

        public var label: String {
            switch self {
            case .achievedNow: "Achieved now"
            case .achievable: "Achievable"
            case .partiallyAchievable: "Partially achievable"
            case .notAchievable: "Not achievable"
            case .unknown: "Unknown"
            }
        }
    }

    public var id: String
    public var outcome: String
    public var status: Status
    public var detail: String

    public init(id: String, outcome: String, status: Status, detail: String) {
        self.id = id
        self.outcome = outcome
        self.status = status
        self.detail = detail
    }
}

public enum OutcomeAssessor {
    public static func assess(
        display: DisplayInfo, modes: [DisplayModeInfo], profiles: [ProfileEvaluation], referenceRefresh: Double
    ) -> [OutcomeAssessment] {
        guard let native = display.nativeResolution.value else {
            return [OutcomeAssessment(
                id: "native", outcome: "Native output", status: .unknown,
                detail: "The native resolution could not be determined.")]
        }
        let current = display.currentMode
        let ref = RefreshRate.label(referenceRefresh)
        let nativeModes = modes.filter { $0.hasNativeFlag && $0.pixels == native }
        let currentIsNative = current.map { $0.hasNativeFlag && $0.pixels == native } ?? false
        var results: [OutcomeAssessment] = []

        // 1. Native physical output.
        results.append(OutcomeAssessment(
            id: "native", outcome: "Native \(native) physical output",
            status: currentIsNative ? .achievedNow : (nativeModes.isEmpty ? .notAchievable : .achievable),
            detail: currentIsNative
                ? "The active mode carries the native flag (inferred; confirm on the monitor's on-screen display)."
                : nativeModes.isEmpty ? "No mode is flagged as native." : "\(nativeModes.count) native-flagged modes are offered."))

        // 2. Reference refresh at native output.
        let nativeAtRef = nativeModes.filter { RefreshRate.isSame($0.refreshRate, referenceRefresh) }
        let rates = Set(nativeModes.map { Int($0.refreshRate.rounded()) }).sorted().map(String.init).joined(separator: ", ")
        let refreshNow = currentIsNative && current.map { RefreshRate.isSame($0.refreshRate, referenceRefresh) } == true
        results.append(OutcomeAssessment(
            id: "refresh", outcome: "\(ref) at native output",
            status: refreshNow ? .achievedNow : (nativeAtRef.isEmpty ? .notAchievable : .achievable),
            detail: nativeAtRef.isEmpty ? "Native modes are offered at \(rates) Hz only." : "Native modes are offered at \(rates) Hz."))

        // 3. Aspect ratio.
        let aspectNow = current?.logical.hasSameAspect(as: native) ?? false
        results.append(OutcomeAssessment(
            id: "aspect", outcome: "Correct \(native.aspectLabel) aspect ratio",
            status: aspectNow ? .achievedNow : .achievable,
            detail: aspectNow ? "The active mode matches the panel's shape." : "Modes with the panel's shape are offered."))

        // 4. HiDPI text at native resolution.
        let sharpHiDPI = modes.filter {
            let path = HiDPIDetection.renderingPath(for: $0, native: native)
            return (path == .nativeHiDPI || path == .supersampledHiDPI) && $0.hasNativeFlag && $0.logical.hasSameAspect(as: native)
        }
        let hiDPINow = current.map { sharpHiDPI.map(\.signature).contains($0.signature) } ?? false
        let hiDPISizes = Set(sharpHiDPI.map { "\($0.logical) (\(percent(of: $0, native: native)))" }).sorted()
        results.append(OutcomeAssessment(
            id: "hidpi", outcome: "HiDPI text at native output",
            status: hiDPINow ? .achievedNow : (sharpHiDPI.isEmpty ? .notAchievable : .achievable),
            detail: sharpHiDPI.isEmpty
                ? "macOS offers no HiDPI mode that renders at or above native resolution with the panel's shape."
                : "Offered only as: \(hiDPISizes.joined(separator: ", "))."))

        // 5. Larger interface with sharp text.
        let largerClean = profiles.filter { $0.target.percent > 100 && $0.selection != nil }
        let largerNow = largerClean.contains { $0.isCurrent }
        results.append(OutcomeAssessment(
            id: "larger", outcome: "Larger interface with sharp text",
            status: largerNow ? .achievedNow : (largerClean.isEmpty ? .notAchievable : .achievable),
            detail: largerClean.isEmpty
                ? "No interface size above 100% keeps sharp text at native output."
                : "Available at: \(largerClean.map { "\($0.target)" }.joined(separator: ", "))."))

        // 6. Intermediate sizes.
        let intermediate = profiles.filter { [125, 150, 175].contains($0.target.percent) }
        let supported = intermediate.filter { $0.selection != nil }
        let status: OutcomeAssessment.Status = supported.isEmpty
            ? .notAchievable : (supported.count == intermediate.count ? .achievable : .partiallyAchievable)
        results.append(OutcomeAssessment(
            id: "intermediate", outcome: "125%, 150% or 175% with sharp text",
            status: status,
            detail: supported.isEmpty
                ? "macOS generates no HiDPI or native-output modes at these sizes for this display. Public APIs cannot create them."
                : "Supported: \(supported.map { "\($0.target)" }.joined(separator: ", "))."))

        // 7. Everything at once.
        let allGoals = largerClean.filter { $0.selection.map { !$0.refresh.isReduction } ?? false }
        results.append(OutcomeAssessment(
            id: "combined", outcome: "Larger UI + sharp text + native output + \(ref) + \(native.aspectLabel), together",
            status: allGoals.contains { $0.isCurrent } ? .achievedNow : (allGoals.isEmpty ? .notAchievable : .achievable),
            detail: allGoals.isEmpty
                ? "No single mode meets every goal."
                : "Only at " + allGoals.compactMap { eval in
                    eval.selection.map { "\(eval.target) (looks like \($0.mode.logical))" }
                }.joined(separator: ", ") + "."))
        return results
    }

    private static func percent(of mode: DisplayModeInfo, native: PixelSize) -> String {
        "\(Int((RecommendationEngine.uiScale(of: mode, native: native) * 100).rounded()))%"
    }
}

/// Per-display section of a diagnostic report.
public struct DisplayDiagnostic: Codable, Sendable, Equatable {
    public var info: DisplayInfo
    public var hiDPIStatus: HiDPIStatus
    public var hiDPIAvailability: HiDPIAvailability
    public var totalModeCount: Int
    public var desktopModes: [DisplayModeInfo]
    public var referenceRefresh: Double?
    public var profiles: [ProfileEvaluation]
    public var recommendation: Recommendation?
    public var outcomes: [OutcomeAssessment]
    public var systemProfiler: Fact<String>
}

/// A complete, exportable snapshot of what ScaleKit can see.
public struct DiagnosticReport: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var generatedAt: Date
    public var scaleKitVersion: String
    public var environment: EnvironmentInfo
    public var preferredRefresh: Double
    public var desiredSize: ScalingTarget
    public var targetMonitor: MonitorMatch?
    public var displays: [DisplayDiagnostic]
    public var verificationRecords: [VerificationRecord]
    public var events: [RecordedDisplayEvent]
}

/// Builds and exports diagnostic reports. Reports are only written when the
/// user asks, and only to local files.
@MainActor
public final class DiagnosticsService {
    private let discovery: DisplayDiscoveryService
    private let modes: DisplayModeService
    private let hiDPI: HiDPIDetectionService
    private let profiles: ScalingProfileService
    private let verifications: VerificationStore

    public init(
        discovery: DisplayDiscoveryService, modes: DisplayModeService, hiDPI: HiDPIDetectionService,
        profiles: ScalingProfileService, verifications: VerificationStore
    ) {
        self.discovery = discovery
        self.modes = modes
        self.hiDPI = hiDPI
        self.profiles = profiles
        self.verifications = verifications
    }

    public func makeReport(
        preferredRefresh: Double,
        desired: ScalingTarget = ScalingTarget(percent: 150),
        events: [RecordedDisplayEvent] = [],
        includeSystemProfiler: Bool = true
    ) async -> DiagnosticReport {
        let displays = discovery.discover()
        let profilerDisplays = includeSystemProfiler ? await SystemProfilerProbe.run() : nil

        let sections = displays.map { display -> DisplayDiagnostic in
            let desktop = modes.desktopModes(for: display.id)
            let context = profiles.context(for: display, preferredRefresh: preferredRefresh)
            let evaluations = profiles.evaluations(for: display, preferredRefresh: preferredRefresh)
            let systemProfiler: Fact<String> = if !includeSystemProfiler {
                .unavailable("Not requested")
            } else if let entry = profilerDisplays?.first(where: { $0.displayID == display.id }) {
                .inferred(entry.summary, reason: "system_profiler SPDisplaysDataType (undocumented JSON keys)")
            } else {
                .unavailable("system_profiler did not report this display")
            }
            return DisplayDiagnostic(
                info: display,
                hiDPIStatus: hiDPI.status(for: display.id),
                hiDPIAvailability: hiDPI.availability(for: display.id),
                totalModeCount: modes.allModes(for: display.id).count,
                desktopModes: desktop,
                referenceRefresh: context?.referenceRefresh,
                profiles: evaluations,
                recommendation: profiles.recommendation(
                    for: display, desired: desired, preferredRefresh: preferredRefresh, evaluations: evaluations),
                outcomes: context.map {
                    OutcomeAssessor.assess(
                        display: display, modes: desktop, profiles: evaluations, referenceRefresh: $0.referenceRefresh)
                } ?? [],
                systemProfiler: systemProfiler)
        }

        Log.diagnostics.info("Built diagnostic report for \(displays.count) display(s)")
        return DiagnosticReport(
            formatVersion: 1,
            generatedAt: Date(),
            scaleKitVersion: ScaleKitInfo.version,
            environment: EnvironmentInfo.current(),
            preferredRefresh: preferredRefresh,
            desiredSize: desired,
            targetMonitor: DisplayDiscoveryService.match(.asusVG34WQML5A, in: displays),
            displays: sections,
            verificationRecords: verifications.records(),
            events: events)
    }

    /// Writes `<basename>.md` and `<basename>.json` into `directory`.
    @discardableResult
    public nonisolated static func write(
        _ report: DiagnosticReport, to directory: URL, basename: String? = nil
    ) throws -> (markdown: URL, json: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let name = basename ?? "scalekit-diagnostics-\(formatter.string(from: report.generatedAt))"
        let markdownURL = directory.appendingPathComponent("\(name).md")
        let jsonURL = directory.appendingPathComponent("\(name).json")
        try Data(DiagnosticMarkdown.render(report).utf8).write(to: markdownURL, options: .atomic)
        try JSONCoding.encoder().encode(report).write(to: jsonURL, options: .atomic)
        return (markdownURL, jsonURL)
    }
}

/// Renders a report as Markdown.
public enum DiagnosticMarkdown {
    public static func render(_ report: DiagnosticReport) -> String {
        var lines: [String] = []
        let date = ISO8601DateFormatter.string(
            from: report.generatedAt, timeZone: .current, formatOptions: [.withInternetDateTime])
        lines.append("# ScaleKit Diagnostic Report")
        lines.append("")
        lines.append("- Generated: \(date) · ScaleKit \(report.scaleKitVersion) · report format \(report.formatVersion)")
        lines.append("- Environment: \(report.environment.summary)\(report.environment.memoryGB.map { " · \($0) GB" } ?? "")")
        lines.append("- Preferred refresh rate: \(RefreshRate.label(report.preferredRefresh)) · desired interface size for recommendations: \(report.desiredSize)")
        lines.append("- Legend: **M** = measured from a public API · **I** = inferred (derived, or from an undocumented source) · **U** = unavailable (macOS does not expose it)")
        lines.append("")

        if let match = report.targetMonitor {
            lines.append("**Target monitor:** \(match.monitorName) → display \(match.displayID), identification confidence **\(match.confidence.label)** (\(match.reasons.joined(separator: "; "))).")
        } else {
            lines.append("**Target monitor:** ASUS VG34WQML5A was not found among the connected displays.")
        }
        lines.append("")

        for section in report.displays {
            render(section, into: &lines)
        }

        lines.append("## Verification records")
        lines.append("")
        if report.verificationRecords.isEmpty {
            lines.append("No mode has been applied and read back by ScaleKit on this Mac yet.")
        } else {
            lines.append("| Display | Mode | Verified at | Observed scale | Environment | Method |")
            lines.append("|---|---|---|---|---|---|")
            for record in report.verificationRecords {
                lines.append("| \(record.displayName) | \(record.signature) | \(ISO8601DateFormatter().string(from: record.verifiedAt)) | \(record.observedScale.map { HiDPIStatus.format($0) + "×" } ?? "—") | \(record.osVersion) | \(record.method) |")
            }
        }
        lines.append("")

        if !report.events.isEmpty {
            lines.append("## Display events observed")
            lines.append("")
            for event in report.events {
                lines.append("- \(ISO8601DateFormatter().string(from: event.date)) — \(event.description)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func render(_ section: DisplayDiagnostic, into lines: inout [String]) {
        let info = section.info
        lines.append("## Display \(info.id) — \(info.displayName)\(info.isMain ? " (main)" : "")")
        lines.append("")

        if !section.outcomes.isEmpty {
            lines.append("### Target outcomes")
            lines.append("")
            lines.append("| Outcome | Status | Detail |")
            lines.append("|---|---|---|")
            for outcome in section.outcomes {
                lines.append("| \(outcome.outcome) | **\(outcome.status.label)** | \(outcome.detail) |")
            }
            lines.append("")
        }

        lines.append("### Facts")
        lines.append("")
        lines.append("| Property | Value | Provenance | Source |")
        lines.append("|---|---|---|---|")
        func row<T>(_ label: String, _ fact: Fact<T>, _ format: (T) -> String) {
            lines.append("| \(label) | \(fact.value.map(format) ?? "—") | \(code(fact.provenance)) | \(fact.source) |")
        }
        row("Name", info.name) { $0 }
        row("Manufacturer", info.manufacturer) { $0 }
        lines.append("| EDID IDs | \(info.identity.hexDescription), serial \(info.identity.serialNumber) | M | CGDisplayVendorNumber / ModelNumber / SerialNumber |")
        lines.append("| Display UUID | \(info.identity.uuid ?? "—") | \(info.identity.uuid == nil ? "U" : "M") | CGDisplayCreateUUIDFromDisplayID |")
        lines.append("| Role | \(info.isMain ? "main" : "secondary"), \(info.isBuiltin ? "built-in" : "external")\(info.isInMirrorSet ? ", mirrored" : "") | M | CGDisplayIsMain / IsBuiltin / IsInMirrorSet |")
        row("Connection", info.connection) { $0 }
        row("Physical size", info.physicalSize) { $0.description }
        row("Pixel density", info.pixelDensity) { String(format: "%.0f PPI", $0) }
        row("Native resolution", info.nativeResolution) { $0.description }
        row("Logical desktop (looks like)", info.logicalResolution) { "\($0) pt" }
        row("Rendered backing store", info.framebufferResolution) { "\($0) px" }
        row("Physical output", info.physicalOutput) { "\($0) px" }
        row("Backing scale factor", info.backingScaleFactor) { HiDPIStatus.format($0) + "×" }
        row("Refresh rate", info.refreshRate) { RefreshRate.label($0) }
        row("Max frames per second", info.maximumFramesPerSecond) { "\($0)" }
        row("system_profiler cross-check", section.systemProfiler) { $0 }
        if let registry = info.registry {
            let range = [registry.minimumRefreshRate, registry.maximumRefreshRate].compactMap { $0 }.map { "\(Int($0))" }.joined(separator: "–")
            lines.append("| EDID refresh range | \(range.isEmpty ? "—" : range + " Hz")\(registry.supportsVariableRefreshRate == true ? ", VRR" : "")\(registry.supportsHDR == true ? ", HDR (PQ)" : "") | I | IORegistry DisplayAttributes (undocumented) |")
        }
        lines.append("")

        lines.append("### HiDPI")
        lines.append("")
        lines.append("- Active: **\(section.hiDPIStatus.label)**, confidence \(section.hiDPIStatus.confidence.label). \(section.hiDPIStatus.explanation)")
        lines.append("- Offered: \(section.hiDPIAvailability.summary)")
        lines.append("")

        lines.append("### Scaling profiles (reference refresh \(section.referenceRefresh.map(RefreshRate.label) ?? "unknown"))")
        lines.append("")
        lines.append("| Target | Status | Mode | Physical output | Rendering | Refresh | Notes |")
        lines.append("|---|---|---|---|---|---|---|")
        for profile in section.profiles {
            if let selection = profile.selection {
                lines.append("| \(profile.target)\(profile.isCurrent ? " (current)" : "") | **\(profile.status.label)** | \(selection.mode.summary) (ID \(selection.mode.modeID)) | \(selection.physicalOutput.value.map { "\($0)" } ?? "unknown") | \(selection.renderingPath.label) | \(selection.mode.refreshLabel) | \(selection.tradeOffs.joined(separator: " ")) |")
            } else {
                let alternatives = profile.alternatives.map { "\($0.uiPercent)% \($0.mode.summary)" }.joined(separator: "; ")
                lines.append("| \(profile.target) | **\(profile.status.label)** | — | — | — | — | \(profile.explanation) Alternatives: \(alternatives.isEmpty ? "none" : alternatives) |")
            }
        }
        lines.append("")

        if let recommendation = section.recommendation {
            lines.append("### Recommendation for a \(recommendation.desired) target")
            lines.append("")
            lines.append(recommendation.headline)
            if let assessment = recommendation.assessment {
                lines.append("")
                lines.append("Score \(RecommendationEngine.format(assessment.score.total))/\(RecommendationEngine.format(assessment.score.maxTotal)):")
                for reason in recommendation.reasons { lines.append("- \(reason)") }
            }
            lines.append("")
        }

        lines.append("### Desktop modes (\(section.desktopModes.count) unique of \(section.totalModeCount) reported)")
        lines.append("")
        lines.append("| ID | Looks like | Backing | Scale | Refresh | Native flag | Rendering | Flags |")
        lines.append("|---|---|---|---|---|---|---|---|")
        let native = info.nativeResolution.value
        for mode in section.desktopModes {
            lines.append("| \(mode.modeID) | \(mode.logical) | \(mode.pixels) | \(HiDPIStatus.format(mode.scaleFactor))× | \(mode.refreshLabel) | \(mode.hasNativeFlag ? "yes" : "no") | \(HiDPIDetection.renderingPath(for: mode, native: native).label) | \(mode.flags.hexDescription) |")
        }
        lines.append("")
    }

    private static func code(_ provenance: Provenance) -> String {
        switch provenance {
        case .measured: "M"
        case .inferred: "I"
        case .unavailable: "U"
        }
    }
}
