import ScaleKitCore
import SwiftUI

extension SupportStatus {
    var tint: Color {
        switch self {
        case .verified: .green
        case .available: .blue
        case .experimental: .orange
        case .unsupported: .secondary
        case .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .verified: "checkmark.seal.fill"
        case .available: "circle.fill"
        case .experimental: "flask.fill"
        case .unsupported: "nosign"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Verified / Available / Experimental / Unsupported / Unknown.
struct StatusBadge: View {
    let status: SupportStatus
    var showsIcon = true

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: status.symbol)
                    .imageScale(.small)
                    .font(.system(size: status == .available ? 6 : 10, weight: .bold))
            }
            Text(status.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(status.tint.opacity(0.13), in: Capsule())
        .fixedSize()
        .help(status.meaning)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.label). \(status.meaning)")
    }
}

/// Verified / Partially verified / Not verified, for a mode read back after a change.
struct VerificationBadge: View {
    let level: ApplyVerification.Level

    private var tint: Color {
        switch level {
        case .verified: .green
        case .partial: .orange
        case .failed: .red
        }
    }

    private var symbol: String {
        switch level {
        case .verified: "checkmark.seal.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var body: some View {
        Label(level.label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.13), in: Capsule())
            .fixedSize()
    }
}

/// A small capsule label such as "Main" or "Current".
struct TagLabel: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}
