import ScaleKitCore
import SwiftUI

/// Shown before any change: before → after, problems, trade-offs and the
/// safety net. Apply starts a reversible trial.
struct ReviewChangeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ChangeRequest
    @ViewState private var acceptsRefreshDrop = false

    private var validation: ModeValidation { request.plan.validation }

    private var canApply: Bool {
        validation.isValid
            && (!validation.requiresRefreshConfirmation || acceptsRefreshDrop)
            && !model.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ChangeTable(rows: request.plan.rows)

            if request.isExplicitAlternative {
                MessageBox(
                    kind: .warning,
                    messages: ["This mode is not a clean scaling profile. You chose it explicitly, with the trade-offs listed below."])
            }
            if !validation.errors.isEmpty {
                MessageBox(kind: .error, messages: validation.errors)
            }
            if !validation.warnings.isEmpty {
                MessageBox(kind: .warning, messages: validation.warnings)
            }
            if validation.requiresRefreshConfirmation {
                Toggle(isOn: $acceptsRefreshDrop) {
                    Text(refreshAcceptance)
                        .fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
            }

            Label {
                Text("You'll have \(request.timeout) seconds to keep this change; otherwise ScaleKit reverts it automatically.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "timer")
                    .foregroundStyle(Color.accentColor)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.confirm(request, acceptRefreshReduction: acceptsRefreshDrop)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(request.title)
                .font(.title2.weight(.semibold))
            Text("\(request.displayName) · \(request.mode.summary)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var refreshAcceptance: String {
        if let drop = request.refreshDrop {
            return "I accept that the refresh rate drops from \(RefreshRate.label(drop.from)) to \(RefreshRate.label(drop.to))"
        }
        return "I accept the lower refresh rate"
    }
}

/// Before → after rows from `ChangePlan.rows`.
private struct ChangeTable: View {
    let rows: [ChangeRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text("Now")
                Text("")
                Text("After")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()
                .gridCellUnsizedAxes(.horizontal)

            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Text(row.before)
                        .foregroundStyle(row.changed ? .primary : .secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(row.changed ? Color.accentColor : Color.secondary.opacity(0.5))
                    Text(row.after)
                        .fontWeight(row.changed ? .semibold : .regular)
                        .foregroundStyle(row.changed ? .primary : .secondary)
                }
                .font(.callout)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.label): \(row.before) to \(row.after)\(row.changed ? "" : ", unchanged")")
            }
        }
        .card()
    }
}

/// A tinted list of errors or warnings.
struct MessageBox: View {
    let kind: Banner.Kind
    let messages: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(kind.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.25), lineWidth: 1))
    }
}
