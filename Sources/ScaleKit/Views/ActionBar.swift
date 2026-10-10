import ScaleKitCore
import SwiftUI

/// Bottom bar: links to the other windows, progress, and Reset / Revert / Apply….
/// Every action opens the review sheet first; nothing is applied directly.
struct ActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: SceneID.preview)
            } label: {
                Label("Preview Sizes", systemImage: "eye")
            }
            .buttonStyle(.link)
            .help("An illustrative preview drawn inside a window. It does not change your display.")

            Button {
                openWindow(id: SceneID.advanced)
            } label: {
                Label("Advanced", systemImage: "info.circle")
            }
            .buttonStyle(.link)
            .help("Modes, display facts, history, diagnostics and compatibility notes")

            Spacer(minLength: 16)

            status
                .frame(maxWidth: 340, alignment: .trailing)

            Button("Reset") { model.requestReset() }
                .disabled(!model.canReset)
                .help(resetHelp)

            Button("Revert") { model.requestRevert() }
                .disabled(!model.canRevert)
                .help(revertHelp)

            Button("Apply…") { model.requestApply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
                .help("Review the change before anything is applied")
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if let busy = busyText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else {
            Text(model.applyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private var busyText: String? {
        if model.isRecoveringAfterLaunch { return "Checking for unfinished changes…" }
        switch model.virtualState {
        case .applying:
            return model.trialSession == nil ? "Setting up the virtual display…" : (model.trialActionLabel ?? "Restoring the previous settings…")
        case .awaitingConfirmation:
            return "Waiting for you to keep or revert the change…"
        case .off, .active:
            break
        }
        switch model.trialState {
        case .applying:
            return model.trialSession == nil
                ? "Applying and reading the mode back…"
                : (model.trialActionLabel ?? "Restoring the previous settings…")
        case .awaitingConfirmation:
            return "Waiting for you to keep or revert the change…"
        case .idle, .finished:
            return nil
        }
    }

    private var resetHelp: String {
        guard let mode = model.resetMode else { return "No clean 100% mode was found for this display." }
        return "Return to 100% (\(mode.summary))."
    }

    private var revertHelp: String {
        guard let backup = model.backup else { return "ScaleKit has not changed this display yet." }
        guard model.revertMode != nil else {
            return "The saved mode (\(backup.mode.summary)) is no longer offered by macOS."
        }
        return "Restore \(backup.mode.summary), saved \(Format.relative(backup.capturedAt)) before ScaleKit's last change."
    }
}
