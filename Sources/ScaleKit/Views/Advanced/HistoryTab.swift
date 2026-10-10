import ScaleKitCore
import SwiftUI

/// The configuration history kept on this Mac, newest first.
struct HistoryTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.historyEntries.isEmpty {
                ContentUnavailableView(
                    "No Changes Yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Every backup, trial, keep and revert ScaleKit performs is listed here."))
            } else {
                List(model.historyEntries) { entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .padding(.top, 8)
        .onAppear { model.reloadHistory() }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    private var style: (symbol: String, tint: Color) {
        switch entry.kind {
        case .kept: ("checkmark.circle.fill", .green)
        case .reverted, .autoReverted, .recovered: ("arrow.uturn.backward.circle.fill", .blue)
        case .applyFailed, .verificationFailed: ("xmark.octagon.fill", .red)
        case .abandoned, .superseded: ("exclamationmark.triangle.fill", .orange)
        case .backupSaved: ("tray.and.arrow.down.fill", .secondary)
        case .trialStarted: ("timer", .accentColor)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.kind.label)
                        .font(.headline)
                    Text(entry.displayName)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.dateTime(entry.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if entry.from != nil || entry.to != nil {
                    Text("\(entry.from?.description ?? "—")  →  \(entry.to?.description ?? "—")")
                        .font(.callout.monospacedDigit())
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}
