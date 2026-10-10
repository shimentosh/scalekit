import ScaleKitCore
import SwiftUI

/// Identifiers for the app's single-instance windows.
enum SceneID {
    static let main = "main"
    static let preview = "preview"
    static let advanced = "advanced"
}

@main
struct ScaleKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("ScaleKit", id: SceneID.main) {
            MainView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 900, height: 660)
        .windowResizability(.contentSize)

        Window("Scaling Preview", id: SceneID.preview) {
            PreviewWindow()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 1020, height: 680)
        .windowResizability(.contentSize)

        Window("Advanced Display Information", id: SceneID.advanced) {
            AdvancedWindow()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 980, height: 660)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("ScaleKit", systemImage: "rectangle.split.3x1") {
            MenuBarContent()
                .environment(appDelegate.model)
        }
    }
}
