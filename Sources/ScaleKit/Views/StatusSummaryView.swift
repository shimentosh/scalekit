import ScaleKitCore
import ScaleKitVirtual
import SwiftUI

/// What the selected monitor is doing right now, plus the recommendation.
struct StatusSummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let display = model.selectedDisplay {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeading("Current state")
                    if let session = model.virtualSession(for: display) {
                        VStack(spacing: 10) {
                            InfoRow("Native resolution", fact: display.nativeResolution) { "\($0)" }
                            InfoRow(label: "Looks like", value: "\(session.plan.points) pt", source: "Virtual display desktop")
                            InfoRow(label: "Rendered at", value: "\(session.plan.pixels) px, scaled to the panel")
                            InfoRow(label: "Refresh rate", value: RefreshRate.label(session.plan.refreshRate))
                            InfoRow(label: "HiDPI", value: "On (2×, virtual display)")
                            InfoRow(label: "Scaling profile", value: "\(session.plan.target) (virtual display)")
                        }
                        .card()
                    } else {
                    VStack(spacing: 10) {
                        InfoRow("Native resolution", fact: display.nativeResolution) { "\($0)" }
                        InfoRow("Looks like", fact: display.logicalResolution) { "\($0)" }
                        InfoRow("Refresh rate", fact: display.refreshRate) { RefreshRate.label($0) }
                        hiDPIRow
                        InfoRow("Physical output", fact: display.physicalOutput, showsChipWhenMeasured: true) { "\($0)" }
                        InfoRow(
                            label: "Scaling profile", value: display.currentProfileLabel,
                            source: "Interface size of the active mode relative to the native resolution")
                    }
                    .card()
                    }
                }
                RecommendationView()
            }
        }
    }

    @ViewBuilder
    private var hiDPIRow: some View {
        if let status = model.hiDPIStatus {
            VStack(alignment: .trailing, spacing: 2) {
                InfoRow(label: "HiDPI", value: status.label, source: status.explanation)
                Text("\(status.confidence.label) confidence")
                    .font(.caption)
                    .foregroundStyle(status.confidence >= .high ? Color.secondary : Color.orange)
                    .help(status.explanation)
            }
        } else {
            InfoRow(label: "HiDPI", value: "Unknown")
        }
    }
}

/// The recommended supported profile with a transparent score breakdown.
struct RecommendationView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showsScore = false

    var body: some View {
        if let plan = model.virtualPlan, let evaluation = model.selectedEvaluation {
            VirtualRecommendationView(plan: plan, evaluation: evaluation)
        } else if let recommendation = model.recommendation {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading("Recommended for \(recommendation.desired)")
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: recommendation.meetsAllCriteria ? "sparkles" : "exclamationmark.triangle")
                            .foregroundStyle(recommendation.meetsAllCriteria ? Color.accentColor : Color.orange)
                        Text(recommendation.headline)
                            .font(.headline)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        if let status = recommendation.status {
                            StatusBadge(status: status)
                        }
                        if recommendation.isCurrent {
                            TagLabel(text: "Active now", tint: .green)
                        }
                    }
                    Text(recommendation.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let profile = recommendation.profile, profile != model.selectedTarget {
                        Button("Show \(profile.description)") { model.selectTarget(profile) }
                            .buttonStyle(.link)
                            .font(.callout)
                    }

                    if let assessment = recommendation.assessment {
                        DisclosureGroup(isExpanded: $showsScore) {
                            ScoreBreakdownView(score: assessment.score)
                                .padding(.top, 6)
                        } label: {
                            Text("Score \(Format.points(assessment.score.total)) of \(Format.points(assessment.score.maxTotal))")
                                .font(.callout)
                                .monospacedDigit()
                        }
                    }
                }
                .card()
            }
        }
    }
}

/// Each scoring component with its points, maximum and reason.
struct ScoreBreakdownView: View {
    let score: ModeScore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(score.components) { component in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(component.name)
                            .font(.caption.weight(.medium))
                            .frame(width: 92, alignment: .leading)
                        ScoreBar(fraction: component.maxPoints > 0 ? component.points / component.maxPoints : 0)
                        Text("\(Format.points(component.points))/\(Format.points(component.maxPoints))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text(component.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Native output and sharp rendering together outweigh readability, so a soft mode never outranks a sharp one of the same shape and refresh rate.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ScoreBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: 5)
    }
}

/// When macOS has no sharp mode for the size, the virtual display is the
/// recommendation: HiDPI, native signal, preferred refresh, same shape.
private struct VirtualRecommendationView: View {
    @Environment(AppModel.self) private var model
    let plan: VirtualScalingPlan
    let evaluation: ProfileEvaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Recommended for \(plan.target.description)")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                    Text("\(plan.target.description) · \(plan.points.description) HiDPI @ \(RefreshRate.label(plan.refreshRate))")
                        .font(.headline)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    StatusBadge(status: model.displayStatus(evaluation, on: model.selectedDisplay))
                    TagLabel(text: "Virtual display", tint: .purple)
                    if model.isVirtualCurrent(evaluation, on: model.selectedDisplay) {
                        TagLabel(text: "Active now", tint: .green)
                    }
                }
                Text("Rendered at \(plan.pixels.description) and scaled down to the panel's native \(plan.native.description), so text stays sharp. Keeps \(RefreshRate.label(plan.refreshRate)) and the panel's \(plan.native.aspectLabel) shape.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
    }
}
