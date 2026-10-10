import SwiftUI

extension Banner.Kind {
    var tint: Color {
        switch self {
        case .success: .green
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.seal.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct BannerView: View {
    let banner: Banner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: banner.kind.symbol)
                .font(.title3)
                .foregroundStyle(banner.kind.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title)
                    .font(.callout.weight(.semibold))
                Text(banner.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss message")
        }
        .padding(12)
        .background(banner.kind.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(banner.kind.tint.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
