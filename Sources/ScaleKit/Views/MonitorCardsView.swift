import ScaleKitCore
import SwiftUI

/// Connected monitors as selectable cards.
struct MonitorCardsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(model.displays) { display in
                    MonitorCard(display: display, isSelected: display.id == model.selectedDisplayID) {
                        model.selectDisplay(display.id)
                    }
                }
            }
            .padding(2)
        }
        .scrollIndicators(.never)
    }
}

struct MonitorCard: View {
    let display: DisplayInfo
    let isSelected: Bool
    let action: () -> Void

    private var subtitle: String {
        [display.manufacturerName, display.nativeResolution.value.map { "\($0)" }, display.connection.value]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var currentLine: String {
        let looksLike = display.logicalResolution.value.map { "Looks like \($0)" } ?? "Looks like —"
        let refresh = display.refreshRate.value.map(RefreshRate.label) ?? "refresh unknown"
        return "\(looksLike) · \(refresh)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AspectGlyph(size: display.nativeResolution.value, isSelected: isSelected)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(display.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        if display.isMain {
                            TagLabel(text: "Main", tint: .accentColor)
                        }
                        if display.currentMode?.isHiDPI == true {
                            TagLabel(text: "HiDPI", tint: .green)
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(currentLine)
                        .font(.callout)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 300, alignment: .leading)
            .card(padding: 12, highlighted: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .help("Show scaling options for \(display.displayName)")
    }
}
