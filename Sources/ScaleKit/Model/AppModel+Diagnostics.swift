import AppKit
import ScaleKitCore

/// Local-only diagnostic reports. Nothing is uploaded.
extension AppModel {
    func generateReport() {
        guard !isGeneratingReport else { return }
        isGeneratingReport = true
        reportMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let report = await services.diagnostics.makeReport(
                preferredRefresh: preferredRefresh, desired: selectedTarget,
                events: services.events.recentEvents)
            diagnosticReport = report
            diagnosticMarkdown = DiagnosticMarkdown.render(report)
            isGeneratingReport = false
        }
    }

    /// Asks for a folder and writes the Markdown and JSON files there.
    func exportReport() {
        guard let report = diagnosticReport else { return }
        let reports = services.paths.reportsDirectory
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)

        let panel = NSOpenPanel()
        panel.title = "Export Diagnostic Report"
        panel.message = "Choose a folder. ScaleKit writes a Markdown and a JSON file there."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = reports
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        do {
            let urls = try DiagnosticsService.write(report, to: folder)
            reportMessage = "Saved \(urls.markdown.lastPathComponent) and \(urls.json.lastPathComponent) to \(folder.path)."
            NSWorkspace.shared.activateFileViewerSelecting([urls.markdown, urls.json])
        } catch {
            reportMessage = "The report could not be saved: \(error.localizedDescription)"
        }
    }

    func showReportsFolder() {
        let reports = services.paths.reportsDirectory
        do {
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            NSWorkspace.shared.open(reports)
        } catch {
            reportMessage = "The reports folder could not be created: \(error.localizedDescription)"
        }
    }
}
