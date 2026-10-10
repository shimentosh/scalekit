import AppKit
import ScaleKitCore

/// Owns the app model and connects it to the application lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The binary may run unbundled (`swift run`), where macOS would
        // otherwise treat it as a background process without a Dock icon.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = ScreenshotRenderer.directoryArgument() {
            // README screenshots: draw offscreen, change nothing, quit.
            for window in NSApp.windows { window.orderOut(nil) }
            ScreenshotRenderer.run(model: model, directory: directory)
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // WindowServer reverts app-only trial changes when the process exits;
        // this records why in the journal and history.
        model.prepareForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The menu bar extra keeps working without windows.
        false
    }
}
