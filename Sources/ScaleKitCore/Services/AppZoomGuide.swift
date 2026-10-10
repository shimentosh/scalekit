import Foundation

/// Per-app text and zoom settings. These enlarge content inside one app only;
/// they are **not** system-wide scaling and never change Finder, the menu bar
/// or other apps.
public struct AppZoomTip: Codable, Sendable, Equatable, Identifiable {
    public var app: String
    public var category: String
    public var shortcut: String?
    public var steps: [String]
    public var scope: String

    public var id: String { app }
}

public enum AppZoomGuide {
    public static let tips: [AppZoomTip] = [
        AppZoomTip(
            app: "Visual Studio Code", category: "Editor", shortcut: "⌘= / ⌘−",
            steps: [
                "Zoom the whole window: View ▸ Appearance ▸ Zoom In, or set \"window.zoomLevel\" in settings.json (each step is about 20%).",
                "Enlarge only code: set \"editor.fontSize\" and \"terminal.integrated.fontSize\".",
            ],
            scope: "VS Code windows only"),
        AppZoomTip(
            app: "Safari", category: "Browser", shortcut: "⌘= / ⌘−",
            steps: ["Set a default for all sites: Safari ▸ Settings ▸ Websites ▸ Page Zoom ▸ When visiting other websites."],
            scope: "Web page content only"),
        AppZoomTip(
            app: "Google Chrome", category: "Browser", shortcut: "⌘= / ⌘−",
            steps: ["Set a default: Settings ▸ Appearance ▸ Page zoom."],
            scope: "Web page content only"),
        AppZoomTip(
            app: "Firefox", category: "Browser", shortcut: "⌘= / ⌘−",
            steps: ["Set a default: Settings ▸ General ▸ Zoom ▸ Default zoom."],
            scope: "Web page content only"),
        AppZoomTip(
            app: "Terminal", category: "Terminal", shortcut: "⌘= / ⌘−",
            steps: ["Make it permanent: Terminal ▸ Settings ▸ Profiles ▸ Text ▸ Font ▸ Change…"],
            scope: "Terminal windows only"),
        AppZoomTip(
            app: "iTerm2", category: "Terminal", shortcut: "⌘= / ⌘−",
            steps: ["Make it permanent: Settings ▸ Profiles ▸ Text ▸ Font size."],
            scope: "iTerm2 windows only"),
        AppZoomTip(
            app: "Finder", category: "System app", shortcut: nil,
            steps: [
                "View ▸ Show View Options (⌘J) ▸ Text size and Icon size, then Use as Defaults.",
                "Sidebar: System Settings ▸ Appearance ▸ Sidebar icon size.",
            ],
            scope: "Finder windows and sidebars only"),
        AppZoomTip(
            app: "macOS Text Size", category: "System setting", shortcut: nil,
            steps: [
                "Search System Settings for \"Text Size\" (under Accessibility ▸ Display). It enlarges text in apps that support it; each supported app is listed there.",
                "It does not enlarge controls, the menu bar or apps that do not support it.",
            ],
            scope: "Supported apps only"),
    ]
}
