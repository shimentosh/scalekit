import ScaleKitCore
import ScaleKitVirtual
import SwiftUI

/// Offered under an unsupported size: sharp HiDPI at that size through a
/// virtual display. Clearly marked experimental.
struct VirtualScalingCard: View {
    @Environment(AppModel.self) private var model
    let plan: VirtualScalingPlan

    private var isActive: Bool {
        model.virtualSession(for: model.selectedDisplay)?.plan.target == plan.target
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Sharp \(plan.target.description) with a virtual display")
                    .font(.subheadline.weight(.semibold))
                if model.isVirtualPlanVerified(plan, on: model.selectedDisplay) {
                    TagLabel(text: "Verified on this Mac", tint: .green)
                } else {
                    TagLabel(text: "Experimental", tint: .purple)
                }
                TagLabel(text: plan.isDownsampled ? "Sharp" : "Soft", tint: plan.isDownsampled ? .green : .orange)
                Spacer(minLength: 0)
            }
            Text("macOS renders a \(plan.points.description) point HiDPI desktop at \(plan.pixels.description) pixels and scales it to the panel's \(plan.native.description). The monitor itself keeps its native signal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 7) {
                InfoRow(label: "Looks like", value: "\(plan.points.description) pt")
                InfoRow(label: "Rendered at", value: "\(plan.pixels.description) px (2× HiDPI)")
                InfoRow(label: "Sampling", value: String(format: "%.2f× the panel's pixels", plan.sampling))
                InfoRow(label: "Refresh rate", value: RefreshRate.label(plan.refreshRate))
            }
            NoteList(notes: plan.tradeOffs)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if isActive {
                    TagLabel(text: "Active", tint: .accentColor)
                    Button("Turn Off") { model.turnOffVirtualScaling() }
                        .disabled(model.isBusy)
                } else {
                    Button("Try \(plan.target.description) (Virtual Display)…") { model.requestVirtualScaling() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartVirtualScaling)
                        .help("Review the change. Nothing happens until you confirm, and it reverts unless you keep it.")
                }
            }
        }
        .card(padding: 12, highlighted: isActive)
    }
}

/// Before → after for virtual scaling, with the safety net spelled out.
struct VirtualReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: VirtualScalingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Try \(request.plan.target.description) on \(request.displayName)")
                        .font(.title3.weight(.semibold))
                    TagLabel(text: "Experimental", tint: .purple)
                }
                Text("Uses a private macOS API: a virtual HiDPI display that your monitor mirrors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                InfoRow(label: "Now", value: request.currentMode?.summary ?? "Unknown")
                InfoRow(label: "Looks like", value: "\(request.plan.points.description) pt")
                InfoRow(label: "Rendered at", value: "\(request.plan.pixels.description) px, scaled to \(request.plan.native.description)")
                InfoRow(label: "Refresh rate", value: RefreshRate.label(request.plan.refreshRate))
            }
            .card(padding: 12)
            MessageBox(kind: .warning, messages: request.plan.tradeOffs)
            Label {
                Text("You'll have \(request.timeout) seconds to keep it; otherwise ScaleKit turns it off. Quitting ScaleKit, or a crash, also turns it off.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "timer").foregroundStyle(Color.accentColor)
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try It") { model.confirmVirtual(request) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// A strip in the main window while virtual scaling is on.
struct VirtualActiveStrip: View {
    @Environment(AppModel.self) private var model
    let session: VirtualScalingSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.physicalName): \(session.plan.target.description) virtual HiDPI scaling is on")
                    .font(.callout.weight(.semibold))
                Text("Looks like \(session.plan.points.description) pt · rendered at \(session.plan.pixels.description) · stays on while ScaleKit runs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn Off") { model.turnOffVirtualScaling() }
                .disabled(model.isBusy)
        }
        .card(padding: 10, highlighted: true)
    }
}
