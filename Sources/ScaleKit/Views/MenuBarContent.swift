import AppKit
import ScaleKitCore
import SwiftUI

/// The menu bar extra. Choosing a size opens the review sheet in the main
/// window; nothing is ever applied from the menu directly.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.displays.isEmpty {
            Text("No displays found")
        }
        ForEach(model.displays) { display in
            Section(display.isMain ? "\(display.displayName) (Main)" : display.displayName) {
                ForEach(model.evaluationsByDisplay[display.id] ?? []) { evaluation in
                    Button(title(for: evaluation, on: display)) {
                        choose(evaluation, on: display)
                    }
                    .disabled(!isChoosable(evaluation, on: display))
                }
            }
        }
        if case .active(let session) = model.virtualState {
            Divider()
            Button("Turn Off \(session.plan.target.description) Virtual Scaling") { model.turnOffVirtualScaling() }
        }
        Divider()
        Button("Open ScaleKit") { open(SceneID.main) }
        Button("Advanced…") { open(SceneID.advanced) }
        Divider()
        Button("Quit ScaleKit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func title(for evaluation: ProfileEvaluation, on display: DisplayInfo) -> String {
        var parts = ["\(evaluation.target)", model.displayStatus(evaluation, on: display).label]
        if model.isCurrent(evaluation, on: display) { parts.append("Current") }
        return parts.joined(separator: "  ·  ")
    }

    private func isChoosable(_ evaluation: ProfileEvaluation, on display: DisplayInfo) -> Bool {
        guard !model.isBusy, !model.isCurrent(evaluation, on: display), model.virtualState.session == nil else { return false }
        if evaluation.selection == nil { return model.virtualPlan(for: evaluation, on: display) != nil }
        return evaluation.status == .verified || evaluation.status == .available
    }

    private func choose(_ evaluation: ProfileEvaluation, on display: DisplayInfo) {
        open(SceneID.main)
        model.chooseFromMenu(displayID: display.id, target: evaluation.target)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}
