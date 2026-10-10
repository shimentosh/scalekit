import ScaleKitCore
import SwiftUI

/// Limits and caveats computed from what macOS reports for the selected display.
struct CompatibilityTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let display = model.selectedDisplay {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("On this display") {
                        ForEach(notes(for: display)) { note in
                            CompatibilityNoteRow(note: note)
                        }
                    }

                    let achievable = outcomes(for: display)
                    if !achievable.isEmpty {
                        section("What can be achieved") {
                            ForEach(achievable) { outcome in
                                OutcomeRow(outcome: outcome)
                            }
                        }
                    }

                    section("Verification records") {
                        verificationRecords(for: display)
                    }

                    section("Experimental approaches (not included)") {
                        Text("Some tools create in-between HiDPI sizes using private or undocumented macOS behaviour. ScaleKit deliberately does not ship these.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Self.experimental) { note in
                            CompatibilityNoteRow(note: note)
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Display Selected", systemImage: "display")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
        }
    }

    // MARK: - Computed notes

    private func notes(for display: DisplayInfo) -> [CompatibilityNote] {
        var notes: [CompatibilityNote] = []
        let evaluations = model.evaluations
        let intermediate = evaluations.filter { [125, 150, 175].contains($0.target.percent) }
        let unsupported = intermediate.filter { $0.status == .unsupported }

        if !intermediate.isEmpty && unsupported.count == intermediate.count {
            notes.append(CompatibilityNote(
                severity: .warning,
                title: "No intermediate HiDPI sizes",
                detail: "macOS offers no sharp 125%, 150% or 175% mode for \(display.displayName). "
                    + (model.hiDPIAvailability?.summary ?? "")
                    + " Public APIs cannot add modes, so these sizes are reported as Unsupported."))
        } else if !unsupported.isEmpty {
            notes.append(CompatibilityNote(
                severity: .info,
                title: "Some intermediate sizes are missing",
                detail: "Unsupported here: \(unsupported.map(\.target.description).joined(separator: ", ")). "
                    + (model.hiDPIAvailability?.summary ?? "")))
        } else if let summary = model.hiDPIAvailability?.summary {
            notes.append(CompatibilityNote(severity: .ok, title: "HiDPI modes", detail: summary))
        }

        if let connection = display.connection.value {
            if connection.localizedCaseInsensitiveContains("HDMI") {
                notes.append(CompatibilityNote(
                    severity: .info,
                    title: "Connected over HDMI (inferred)",
                    detail: "Read from an undocumented IORegistry key: \(connection). The modes and refresh rates macOS offers depend on the link and the monitor's EDID; a DisplayPort or USB-C connection may expose a different list. ScaleKit only uses the modes macOS reports."))
            } else {
                notes.append(CompatibilityNote(
                    severity: .ok, title: "Connection (inferred)",
                    detail: "\(connection), read from an undocumented IORegistry key."))
            }
        }

        notes.append(refreshNote(for: display))

        if display.physicalOutput.provenance != .measured {
            notes.append(CompatibilityNote(
                severity: .info,
                title: "Physical output is not measured",
                detail: display.physicalOutput.source))
        }
        return notes
    }

    private func refreshNote(for display: DisplayInfo) -> CompatibilityNote {
        let nativeRates = Set(model.desktopModes.filter(\.hasNativeFlag).map { Int($0.refreshRate.rounded()) })
            .filter { $0 > 0 }
            .sorted()
        var parts: [String] = []
        if let registry = display.registry,
           let min = registry.minimumRefreshRate, let max = registry.maximumRefreshRate {
            var range = "The monitor reports a \(Int(min))–\(Int(max)) Hz range (inferred from IORegistry)"
            if registry.supportsVariableRefreshRate == true { range += " with variable refresh" }
            parts.append(range + ".")
        }
        if !nativeRates.isEmpty {
            parts.append("Native-output modes are offered at \(nativeRates.map(String.init).joined(separator: ", ")) Hz.")
        }
        let preferred = model.preferredRefresh
        let offersPreferred = nativeRates.contains { RefreshRate.isSame(Double($0), preferred) }
        if let reference = model.referenceRefresh {
            parts.append("Profiles are matched at \(RefreshRate.label(reference))"
                + (offersPreferred ? " (your preferred rate)." : "; your preferred \(RefreshRate.label(preferred)) is not offered at native output."))
        }
        return CompatibilityNote(
            severity: offersPreferred ? .ok : .warning,
            title: "Refresh rates",
            detail: parts.joined(separator: " "))
    }

    private func outcomes(for display: DisplayInfo) -> [OutcomeAssessment] {
        guard let reference = model.referenceRefresh else { return [] }
        return OutcomeAssessor.assess(
            display: display, modes: model.desktopModes, profiles: model.evaluations, referenceRefresh: reference)
    }

    @ViewBuilder
    private func verificationRecords(for display: DisplayInfo) -> some View {
        let records = model.verificationRecords.filter { $0.displayKey == display.key }
        Text("This Mac: \(model.services.environment.summary)")
            .font(.callout)
            .foregroundStyle(.secondary)
        if records.isEmpty {
            Text("No mode has been applied and read back by ScaleKit on this display yet. Modes show as Verified only after that happens.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.signature.description)
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                        StatusBadge(status: .verified)
                        Spacer()
                        Text(Format.dateTime(record.verifiedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(record.osVersion) · \(record.hardwareModel)\(record.observedScale.map { " · observed scale \(Format.scale($0))" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Method: \(record.method)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .textSelection(.enabled)
                .card(padding: 10)
            }
        }
    }

    // MARK: - Static content

    private static let experimental: [CompatibilityNote] = [
        CompatibilityNote(
            severity: .experimental,
            title: "Virtual-display mirroring",
            detail: "Creates a virtual HiDPI display with the private CGVirtualDisplay API and mirrors the monitor to it to fake in-between sizes such as 150%. Private and unsupported: it can break with any macOS update, adds GPU work and can affect refresh rate, colour and HDR."),
        CompatibilityNote(
            severity: .experimental,
            title: "Display override property lists",
            detail: "Adds custom \"scale-resolutions\" in an undocumented override file under /Library/Displays so macOS lists extra HiDPI modes. Needs administrator rights, may be ignored after updates or on some Macs, and a bad file can leave a display unusable."),
    ]
}

struct CompatibilityNote: Identifiable {
    enum Severity {
        case ok, info, warning, experimental
    }

    let id = UUID()
    var severity: Severity
    var title: String
    var detail: String
}

private struct CompatibilityNoteRow: View {
    let note: CompatibilityNote

    private var style: (symbol: String, tint: Color) {
        switch note.severity {
        case .ok: ("checkmark.circle.fill", .green)
        case .info: ("info.circle.fill", .blue)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .experimental: ("flask.fill", .orange)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(note.title)
                        .font(.headline)
                    if note.severity == .experimental {
                        StatusBadge(status: .experimental)
                        TagLabel(text: "Not included")
                    }
                }
                Text(note.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12)
    }
}

private struct OutcomeRow: View {
    let outcome: OutcomeAssessment

    private var tint: Color {
        switch outcome.status {
        case .achievedNow: .green
        case .achievable: .blue
        case .partiallyAchievable: .orange
        case .notAchievable: .secondary
        case .unknown: .gray
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(outcome.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(tint.opacity(0.13), in: Capsule())
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.outcome)
                    .font(.callout.weight(.medium))
                Text(outcome.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
