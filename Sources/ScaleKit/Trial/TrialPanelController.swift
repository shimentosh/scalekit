import AppKit
import ScaleKitCore
import SwiftUI

/// A borderless-looking floating panel that can take keyboard focus, so
/// Return and Esc work even though the app's own windows may be off screen.
final class TrialPanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Esc reverts. SwiftUI's .cancelAction usually handles it first; both
        // paths are safe because RecoveryService ignores duplicate events.
        onCancel?()
    }
}

/// Shows "Keep these display settings?" centred on every screen while a trial
/// awaits confirmation. It does not depend on the main window: the mode
/// change itself can move or hide that window.
@MainActor
final class TrialPanelController {
    private weak var model: AppModel?
    private var panels: [TrialPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var focusDisplayID: UInt32?

    init(model: AppModel) {
        self.model = model
    }

    var isShowing: Bool { !panels.isEmpty }

    func show(focusing displayID: UInt32) {
        focusDisplayID = displayID
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Re-position only: taking focus again here would let someone
                // typing in another app press Return (Keep) by accident.
                MainActor.assumeIsolated { self?.layout(takeFocus: false) }
            }
        }
        NSApp.activate()
        layout(takeFocus: true)
    }

    func close() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        for panel in panels {
            panel.onCancel = nil
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        focusDisplayID = nil
    }

    /// One panel per screen, centred. Reuses panels when the screen count is
    /// unchanged and rebuilds them otherwise.
    private func layout(takeFocus: Bool) {
        guard model != nil else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        if panels.count != screens.count {
            for panel in panels {
                panel.orderOut(nil)
                panel.close()
            }
            panels = screens.map { _ in makePanel() }
        }
        for (panel, screen) in zip(panels, screens) {
            center(panel, on: screen)
        }

        let focusIndex = screens.firstIndex { $0.displayID == focusDisplayID }
            ?? screens.firstIndex { $0 == NSScreen.main }
            ?? 0
        for (index, panel) in panels.enumerated() where index != focusIndex || !takeFocus {
            panel.orderFrontRegardless()
        }
        if takeFocus {
            NSApp.activate()
            panels[focusIndex].makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel() -> TrialPanel {
        let panel = TrialPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .alertPanel
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.onCancel = { [weak self] in self?.model?.revertTrial() }

        if let model {
            let host = NSHostingView(rootView: TrialPanelView().environment(model))
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
        }
        return panel
    }

    private func center(_ panel: NSPanel, on screen: NSScreen) {
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.midY - size.height / 2).rounded()))
    }
}
