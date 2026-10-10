import ScaleKitCore
import SwiftUI

extension Provenance {
    var tint: Color {
        switch self {
        case .measured: .green
        case .inferred: .orange
        case .unavailable: .gray
        }
    }

    var symbol: String {
        switch self {
        case .measured: "gauge.with.dots.needle.67percent"
        case .inferred: "point.3.connected.trianglepath.dotted"
        case .unavailable: "minus.circle"
        }
    }

    var meaning: String {
        switch self {
        case .measured: "Read directly from a public macOS API."
        case .inferred: "Derived from other values, or read from an undocumented source."
        case .unavailable: "macOS does not expose this information."
        }
    }
}

/// Measured / Inferred / Unavailable, with the source on hover.
struct ProvenanceChip: View {
    let provenance: Provenance
    var source: String?

    var body: some View {
        Text(provenance.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(provenance.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(provenance.tint.opacity(0.45), lineWidth: 0.75))
            .fixedSize()
            .help(source.map { "\(provenance.meaning)\nSource: \($0)" } ?? provenance.meaning)
            .accessibilityLabel("\(provenance.label). \(source ?? provenance.meaning)")
    }
}
