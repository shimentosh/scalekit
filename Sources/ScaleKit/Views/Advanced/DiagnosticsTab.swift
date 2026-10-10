import ScaleKitCore
import SwiftUI

/// Generate, read and export a local diagnostic report.
struct DiagnosticsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    model.generateReport()
                } label: {
                    Label("Generate Report", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isGeneratingReport)

                Button("Export…") { model.exportReport() }
                    .disabled(model.diagnosticReport == nil)
                    .help("Save the report as Markdown and JSON in a folder you choose")

                Button("Show Reports Folder") { model.showReportsFolder() }
                    .help(model.services.paths.reportsDirectory.path)

                if model.isGeneratingReport {
                    ProgressView().controlSize(.small)
                    Text("Reading displays and running a read-only system_profiler check…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Label("Reports stay on this Mac and are written only when you ask. Nothing is uploaded.", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let message = model.reportMessage {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            Group {
                if model.diagnosticMarkdown.isEmpty {
                    ContentUnavailableView(
                        "No Report Yet", systemImage: "doc.text",
                        description: Text("Generate a report to see every measured and inferred value, the scaling profiles and the mode list."))
                } else {
                    ReadOnlyTextView(text: model.diagnosticMarkdown)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .padding(.top, 8)
    }
}
