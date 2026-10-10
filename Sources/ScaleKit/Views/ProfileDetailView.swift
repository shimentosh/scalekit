import ScaleKitCore
import SwiftUI

/// Everything about the selected interface size on the selected monitor.
struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let evaluation = model.selectedEvaluation, let display = model.selectedDisplay {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(evaluation.target.description) interface")
                        .font(.title3.weight(.semibold))
                    StatusBadge(status: model.displayStatus(evaluation, on: display))
                    if model.isCurrent(evaluation, on: display) {
                        TagLabel(text: "Current", tint: .accentColor)
                    }
                    Spacer(minLength: 0)
                }
                if let selection = evaluation.selection {
                    SelectionDetails(evaluation: evaluation, selection: selection, display: display)
                } else {
                    if let plan = model.virtualPlan {
                        VirtualScalingCard(plan: plan)
                    }
                    UnsupportedDetails(evaluation: evaluation)
                }
            }
            .card(padding: 16)
        }
    }
}

/// Details of the clean mode a profile maps to.
private struct SelectionDetails: View {
    let evaluation: ProfileEvaluation
    let selection: ModeAssessment
    let display: DisplayInfo

    private var mode: DisplayModeInfo { selection.mode }

    private var expectedSize: String {
        let factor = selection.uiScale
        if abs(factor - 1) < 0.01 { return "Native size: one point per panel pixel" }
        return "Text and controls appear \(Format.scale(factor)) as large as at native resolution"
    }

    private var workspace: String {
        guard let native = display.nativeResolution.value, native.area > 0 else { return "\(mode.logical) pt" }
        let share = Int((Double(mode.logical.area) / Double(native.area) * 100).rounded())
        return "\(mode.logical) pt (\(share)% of native area)"
    }

    private var hiDPI: String {
        mode.isHiDPI ? "On (\(Format.scale(mode.scaleFactor)) backing)" : "Off (1×)"
    }

    private var refresh: String {
        guard let current = display.currentMode?.refreshRate else { return mode.refreshLabel }
        switch RefreshComparison.compare(from: current, to: mode.refreshRate) {
        case .unchanged: return "\(mode.refreshLabel) (unchanged)"
        case .increased(let from, _): return "\(mode.refreshLabel) (up from \(RefreshRate.label(from)))"
        case .decreased(let from, _): return "\(mode.refreshLabel) (down from \(RefreshRate.label(from)))"
        case .unknown: return mode.refreshLabel
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(expectedSize)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 9) {
                InfoRow(label: "Profile", value: "\(evaluation.target) · \(mode.summary)", source: "Display mode \(mode.modeID)")
                InfoRow(label: "Looks like", value: workspace, source: "Logical desktop size in points")
                InfoRow("Physical output", fact: selection.physicalOutput, showsChipWhenMeasured: true) { "\($0)" }
                InfoRow(label: "Rendered at", value: "\(mode.pixels) px", source: "Backing store size")
                InfoRow(label: "HiDPI", value: hiDPI)
                InfoRow(label: "Rendering path", value: selection.renderingPath.label)
                InfoRow(label: "Refresh rate", value: refresh)
                InfoRow(
                    label: "Verification",
                    value: evaluation.status == .verified ? "Verified on this Mac" : "Not yet verified on this Mac",
                    source: evaluation.status.meaning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Trade-offs")
                    .font(.subheadline.weight(.semibold))
                if selection.tradeOffs.isEmpty {
                    Label("None: native output, sharp text and the panel's own shape.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    NoteList(notes: selection.tradeOffs)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Why a profile is unsupported, and the closest modes macOS does offer.
private struct UnsupportedDetails: View {
    @Environment(AppModel.self) private var model
    let evaluation: ProfileEvaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(evaluation.status == .unknown ? "Not enough information"
                    : (model.virtualPlan != nil ? "Why macOS has no built-in mode for this size" : "Why it isn't available"))
                    .font(.subheadline.weight(.semibold))
                Text(evaluation.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !evaluation.alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Closest alternatives")
                        .font(.subheadline.weight(.semibold))
                    Text("ScaleKit never switches to these automatically. Choose one only if you accept its trade-offs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(evaluation.alternatives) { alternative in
                        AlternativeRow(
                            alternative: alternative,
                            profile: model.evaluations.first { $0.selection?.mode.signature == alternative.mode.signature }?.target,
                            isChosen: model.chosenAlternative?.signature == alternative.mode.signature,
                            isDisabled: model.isBusy
                        ) {
                            model.requestAlternative(alternative)
                        }
                    }
                }
            }
        }
    }
}

private struct AlternativeRow: View {
    let alternative: ModeAssessment
    /// The standard profile this mode is the clean mapping of, if any.
    let profile: ScalingTarget?
    let isChosen: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(alternative.uiPercent)%")
                        .font(.system(.headline, design: .rounded))
                        .monospacedDigit()
                    Text(alternative.mode.summary)
                        .font(.callout)
                        .monospacedDigit()
                    StatusBadge(status: alternative.status)
                    TagLabel(
                        text: alternative.renderingPath.isSharp ? "Sharp" : "Soft",
                        tint: alternative.renderingPath.isSharp ? .green : .orange)
                }
                Text(profile.map { "The \($0) profile · \(alternative.renderingPath.label)" } ?? alternative.renderingPath.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !alternative.tradeOffs.isEmpty {
                    NoteList(notes: alternative.tradeOffs)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if alternative.isCurrent {
                TagLabel(text: "Current", tint: .accentColor)
            } else {
                Button("Use this mode…", action: action)
                    .disabled(isDisabled)
                    .help("Review switching to \(alternative.mode.summary). Nothing changes until you confirm.")
            }
        }
        .card(padding: 12, highlighted: isChosen)
    }
}
