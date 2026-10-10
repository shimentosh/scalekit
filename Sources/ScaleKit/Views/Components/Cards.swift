import ScaleKitCore
import SwiftUI

/// A rounded, subtly filled container used for grouped content.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHighlighted ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.background.secondary)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08),
                                  lineWidth: isHighlighted ? 1.5 : 1))
    }
}

extension View {
    func card(padding: CGFloat = 14, highlighted: Bool = false) -> some View {
        modifier(CardBackground(padding: padding, isHighlighted: highlighted))
    }
}

/// Small uppercase section heading.
struct SectionHeading: View {
    let title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A label/value row with an optional provenance chip and a tooltip source.
struct InfoRow: View {
    let label: String
    let value: String
    var provenance: Provenance?
    var source: String?
    var showsChipWhenMeasured = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            if let provenance, showsChipWhenMeasured || provenance != .measured {
                ProvenanceChip(provenance: provenance, source: source)
            }
        }
        .font(.callout)
        .help(source ?? "")
    }
}

extension InfoRow {
    init<T>(_ label: String, fact: Fact<T>, showsChipWhenMeasured: Bool = false, format: (T) -> String) {
        self.init(
            label: label, value: Format.value(fact, format), provenance: fact.provenance, source: fact.source,
            showsChipWhenMeasured: showsChipWhenMeasured)
    }
}

/// A bullet list of short notes.
struct NoteList: View {
    let notes: [String]
    var symbol = "circle.fill"
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: symbol == "circle.fill" ? 4 : 10, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 10)
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
