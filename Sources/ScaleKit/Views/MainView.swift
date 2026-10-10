import ScaleKitCore
import SwiftUI

/// The main window: monitors on top, current state on the left, interface
/// sizes on the right and the actions along the bottom.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.displays.isEmpty {
                ContentUnavailableView {
                    Label("No Displays Found", systemImage: "display.trianglebadge.exclamationmark")
                } description: {
                    Text("ScaleKit could not read any connected displays.")
                } actions: {
                    Button("Check Again") { model.refreshNow() }
                }
            } else {
                content
            }
        }
        .frame(minWidth: 860, idealWidth: 900, maxWidth: 1320, minHeight: 600, idealHeight: 660, maxHeight: 1100)
        .navigationSubtitle(model.selectedDisplay?.displayName ?? "")
        .sheet(item: $model.pendingChange) { request in
            ReviewChangeSheet(request: request)
        }
        .sheet(item: $model.pendingVirtual) { request in
            VirtualReviewSheet(request: request)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                if let banner = model.banner {
                    BannerView(banner: banner) { model.banner = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if case .active(let session) = model.virtualState {
                    VirtualActiveStrip(session: session)
                }
                MonitorCardsView()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)

            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    StatusSummaryView()
                        .padding(20)
                }
                .frame(width: 340)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ProfileSelectorView()
                        ProfileDetailView()
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            ActionBar()
        }
        .animation(.snappy, value: model.banner)
    }
}
