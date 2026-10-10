import ScaleKitCore
import SwiftUI

/// Per-app zoom guidance for when no system-wide size fits.
struct AppZoomTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MessageBox(
                    kind: .info,
                    messages: ["These settings enlarge content inside individual apps. They are not system-wide scaling and do not change Finder, the menu bar, or other apps."])

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(AppZoomGuide.tips) { tip in
                        AppZoomTipCard(tip: tip)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
        }
    }
}

private struct AppZoomTipCard: View {
    let tip: AppZoomTip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tip.app)
                    .font(.headline)
                Text(tip.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let shortcut = tip.shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced().weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75))
                }
            }
            NoteList(notes: tip.steps)
                .font(.callout)
            Label(tip.scope, systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .textSelection(.enabled)
        .card(padding: 12)
    }
}
