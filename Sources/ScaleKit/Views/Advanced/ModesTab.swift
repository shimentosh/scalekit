import ScaleKitCore
import SwiftUI

/// Every mode macOS reports for the selected display.
struct ModesTab: View {
    @Environment(AppModel.self) private var model
    @ViewState private var includesAllModes = false

    private struct Row: Identifiable {
        let id: Int
        let mode: DisplayModeInfo
        let path: RenderingPath
        let isActive: Bool
        let isVerified: Bool
        let isDesktop: Bool
    }

    private var rows: [Row] {
        guard let display = model.selectedDisplay else { return [] }
        let native = display.nativeResolution.value
        let current = display.currentMode?.signature
        let desktopIDs = Set(model.desktopModes.map(\.modeID))
        let source = includesAllModes ? model.allModes : model.desktopModes
        return source.enumerated().map { index, mode in
            Row(
                id: index, mode: mode,
                path: HiDPIDetection.renderingPath(for: mode, native: native),
                isActive: mode.signature == current,
                isVerified: model.verifiedSignatures.contains(mode.signature),
                isDesktop: desktopIDs.contains(mode.modeID))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.desktopModes.count) unique desktop modes · \(model.allModes.count) reported including HiDPI duplicates")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Include non-desktop and duplicate modes", isOn: $includesAllModes)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Table(rows) {
                TableColumn("ID") { row in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(row.isActive ? Color.green : Color.clear)
                            .frame(width: 6, height: 6)
                        Text(verbatim: "\(row.mode.modeID)")
                    }
                    .help(row.isActive ? "Active mode" : "")
                }
                .width(min: 44, ideal: 56, max: 70)
                TableColumn("Looks like") { row in cell(row, "\(row.mode.logical)") }
                    .width(min: 90, ideal: 100)
                TableColumn("Backing") { row in cell(row, "\(row.mode.pixels)") }
                    .width(min: 90, ideal: 100)
                TableColumn("Scale") { row in cell(row, Format.scale(row.mode.scaleFactor)) }
                    .width(min: 40, ideal: 48, max: 60)
                TableColumn("Refresh") { row in cell(row, row.mode.refreshLabel) }
                    .width(min: 56, ideal: 64, max: 90)
                TableColumn("Native") { row in
                    Image(systemName: row.mode.hasNativeFlag ? "checkmark" : "minus")
                        .foregroundStyle(row.mode.hasNativeFlag ? Color.primary : Color.secondary.opacity(0.5))
                        .help(row.mode.hasNativeFlag ? "Carries kDisplayModeNativeFlag" : "Not flagged native")
                }
                .width(min: 44, ideal: 50, max: 60)
                TableColumn("Rendering path") { row in
                    HStack(spacing: 5) {
                        Image(systemName: row.path.isSharp ? "circle.fill" : "circle.dashed")
                            .font(.system(size: 7))
                            .foregroundStyle(row.path.isSharp ? Color.green : Color.orange)
                        cell(row, row.path.label)
                    }
                }
                .width(min: 150, ideal: 190)
                TableColumn("Verified") { row in
                    if row.isActive || row.isVerified {
                        Label(row.isActive ? "Active" : "Verified", systemImage: "checkmark.seal.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 72, max: 90)
                TableColumn("Flags") { row in
                    Text(row.mode.flags.hexDescription)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .help(row.mode.flags.names.joined(separator: ", ") + (row.isDesktop ? "" : " · not a desktop mode"))
                }
                .width(min: 84, ideal: 92)
            }
            .monospacedDigit()

            Text("Sharp rendering paths are marked with a solid dot. Hover over a flags value to decode it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func cell(_ row: Row, _ text: String) -> some View {
        Text(text)
            .fontWeight(row.isActive ? .semibold : .regular)
            .foregroundStyle(row.isDesktop ? Color.primary : Color.secondary)
    }
}
