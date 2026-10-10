import ScaleKitCore
import SwiftUI

/// Technical detail for people who want to see exactly what ScaleKit sees.
struct AdvancedWindow: View {
    @Environment(AppModel.self) private var model
    @ViewState private var tab: Tab = .modes

    enum Tab: Hashable {
        case modes, display, history, diagnostics, compatibility, appZoom
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Display", selection: Binding(
                    get: { model.selectedDisplayID ?? 0 },
                    set: { model.selectDisplay($0) }
                )) {
                    ForEach(model.displays) { display in
                        Text(display.isMain ? "\(display.displayName) (Main)" : display.displayName)
                            .tag(display.id)
                    }
                }
                .fixedSize()
                Spacer()
                Button {
                    model.refreshNow()
                    model.reloadHistory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the displays again")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)

            TabView(selection: $tab) {
                ModesTab()
                    .tabItem { Text("Modes") }
                    .tag(Tab.modes)
                DisplayInfoTab()
                    .tabItem { Text("Display") }
                    .tag(Tab.display)
                HistoryTab()
                    .tabItem { Text("History") }
                    .tag(Tab.history)
                DiagnosticsTab()
                    .tabItem { Text("Diagnostics") }
                    .tag(Tab.diagnostics)
                CompatibilityTab()
                    .tabItem { Text("Compatibility") }
                    .tag(Tab.compatibility)
                AppZoomTab()
                    .tabItem { Text("App Zoom") }
                    .tag(Tab.appZoom)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 6)
        }
        .frame(minWidth: 860, idealWidth: 980, maxWidth: 1600, minHeight: 520, idealHeight: 660, maxHeight: 1200)
    }
}
