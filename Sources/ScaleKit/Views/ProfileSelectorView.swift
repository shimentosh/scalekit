import ScaleKitCore
import SwiftUI

/// The five interface sizes with their status on the selected monitor.
struct ProfileSelectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                "Interface size",
                subtitle: model.selectedDisplay.map { "How large text and controls appear on \($0.displayName)." })
            HStack(spacing: 10) {
                ForEach(model.evaluations) { evaluation in
                    ProfileTile(
                        evaluation: evaluation,
                        status: model.displayStatus(evaluation, on: model.selectedDisplay),
                        isCurrent: model.isCurrent(evaluation, on: model.selectedDisplay),
                        virtualSize: model.virtualPlan(for: evaluation, on: model.selectedDisplay)?.points,
                        native: model.selectedDisplay?.nativeResolution.value,
                        isSelected: evaluation.target == model.selectedTarget
                    ) {
                        model.selectTarget(evaluation.target)
                    }
                }
            }
        }
    }
}

struct ProfileTile: View {
    let evaluation: ProfileEvaluation
    let status: SupportStatus
    let isCurrent: Bool
    /// Looks-like size when the profile is produced by a virtual display.
    let virtualSize: PixelSize?
    let native: PixelSize?
    let isSelected: Bool
    let action: () -> Void

    private var looksLike: String {
        if let selection = evaluation.selection { return "\(selection.mode.logical)" }
        if let virtualSize { return "\(virtualSize)" }
        if let native { return "≈ \(evaluation.target.idealLogicalSize(native: native))" }
        return "—"
    }

    private var isUnavailable: Bool {
        status == .unsupported || status == .unknown
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(evaluation.target.description)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isUnavailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(looksLike)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                StatusBadge(status: status, showsIcon: false)
                Text(isCurrent ? "Current" : " ")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 12)
            .padding(.bottom, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .card(padding: 0, highlighted: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(evaluation.target): \(virtualSize == nil ? status.meaning : "Produced with a virtual HiDPI display (experimental, private API).")")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(evaluation.target), \(status.label)\(isCurrent ? ", current" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
