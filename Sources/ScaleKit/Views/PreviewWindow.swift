import AppKit
import ScaleKitCore
import SwiftUI

/// An illustrative preview of each interface size, drawn inside this window.
/// It never changes the display.
struct PreviewWindow: View {
    @Environment(AppModel.self) private var model
    @ViewState private var target = ScalingTarget(percent: 150)
    @ViewState private var hasSyncedTarget = false

    private var currentScale: Double {
        model.selectedDisplay?.currentUIScale ?? 1
    }

    private var relativeScale: Double {
        target.factor / max(0.25, currentScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            disclaimer
            controls
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                MockDesktopView(scale: relativeScale)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .overlay(alignment: .bottomLeading) {
                        Label("Illustration", systemImage: "eye")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ScrollView {
                    DensityPanel(target: target, relativeScale: relativeScale)
                }
                .frame(width: 260)
            }
            .padding(20)
        }
        .frame(minWidth: 880, idealWidth: 1020, maxWidth: 1800, minHeight: 560, idealHeight: 680, maxHeight: 1200)
        .onAppear {
            guard !hasSyncedTarget else { return }
            hasSyncedTarget = true
            target = model.selectedTarget
        }
    }

    private var disclaimer: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.title3)
            Text("Illustrative preview — drawn inside this window only. It does not change your display.")
                .font(.callout.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color.yellow.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Display", selection: Binding(
                get: { model.selectedDisplayID ?? 0 },
                set: { model.selectDisplay($0) }
            )) {
                ForEach(model.displays) { display in
                    Text(display.displayName).tag(display.id)
                }
            }
            .fixedSize()

            Spacer(minLength: 8)

            Picker("Interface size", selection: $target) {
                ForEach(ScalingTarget.standard) { option in
                    Text(option.description).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
        }
    }
}

/// Density numbers for the chosen size, next to the current ones.
private struct DensityPanel: View {
    @Environment(AppModel.self) private var model
    let target: ScalingTarget
    let relativeScale: Double

    private var display: DisplayInfo? { model.selectedDisplay }
    private var evaluation: ProfileEvaluation? {
        model.evaluations.first { $0.target == target }
    }

    /// The real "looks like" size when macOS offers the profile, else the ideal one.
    private var logical: (size: PixelSize, isOffered: Bool)? {
        if let selection = evaluation?.selection { return (selection.mode.logical, true) }
        guard let native = display?.nativeResolution.value else { return nil }
        return (target.idealLogicalSize(native: native), false)
    }

    private var relativeText: String {
        if abs(relativeScale - 1) < 0.01 { return "Same as now" }
        return relativeScale > 1
            ? "\(Format.scale(relativeScale)) larger than now"
            : "\(Format.scale(relativeScale)) the current size"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(target.description)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                if let evaluation {
                    StatusBadge(status: evaluation.status)
                }
            }

            if let display {
                Text(display.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            StatTile(title: "Interface", value: relativeText, caption: "Relative to how \(display?.displayName ?? "the display") looks now")

            if let logical {
                StatTile(
                    title: "Desktop looks like",
                    value: "\(logical.isOffered ? "" : "≈ ")\(logical.size)",
                    caption: logical.isOffered
                        ? "Points of workspace with this profile"
                        : "Not offered sharply by macOS on this display; shown for comparison only")
                let capacity = EditorDensity.capacity(for: logical.size)
                StatTile(
                    title: "Code editor, full screen",
                    value: "≈ \(capacity.columns) × \(capacity.lines)",
                    caption: "Columns × lines of 13 pt monospaced text")
            }

            if let current = display?.logicalResolution.value {
                let capacity = EditorDensity.capacity(for: current)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(display?.currentProfileLabel ?? "—") · looks like \(current) · ≈ \(capacity.columns) × \(capacity.lines)")
                        .font(.callout)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if evaluation?.status == .unsupported {
                MessageBox(
                    kind: .info,
                    messages: ["macOS has no sharp \(target) mode for this display. The main window lists the closest modes it does offer."])
            }

            Text("Estimates assume SF Mono 13 pt with a \(Int(EditorDensity.lineHeight)) pt line height, a \(Int(EditorDensity.gutter)) pt gutter and about \(Int(EditorDensity.chrome)) pt of menu bar and editor chrome.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, 4)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }
}

/// Rough capacity of a full-screen code editor at 13 pt.
@MainActor
enum EditorDensity {
    static let fontSize: CGFloat = 13
    static let lineHeight: CGFloat = 19
    static let gutter: CGFloat = 64
    /// Menu bar, title/tab bar, breadcrumbs and status bar.
    static let chrome: CGFloat = 112

    static let advance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        return width > 0 ? width : fontSize * 0.6
    }()

    static func capacity(for logical: PixelSize) -> (columns: Int, lines: Int) {
        let columns = (CGFloat(logical.width) - gutter) / advance
        let lines = (CGFloat(logical.height) - chrome) / lineHeight
        return (max(0, Int(columns.rounded(.down))), max(0, Int(lines.rounded(.down))))
    }
}
