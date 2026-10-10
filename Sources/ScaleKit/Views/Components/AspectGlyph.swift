import ScaleKitCore
import SwiftUI

/// A small monitor drawn with the panel's real proportions.
struct AspectGlyph: View {
    let size: PixelSize?
    var isSelected = false
    var maxWidth: CGFloat = 64
    var maxHeight: CGFloat = 36

    private var screenSize: CGSize {
        let ratio = size.map { $0.aspectRatio > 0 ? $0.aspectRatio : 16.0 / 9 } ?? 16.0 / 9
        let width = min(maxWidth, maxHeight * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(LinearGradient(
                    colors: isSelected
                        ? [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.25)]
                        : [Color.primary.opacity(0.16), Color.primary.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.35), lineWidth: 1.25))
                .overlay {
                    if let size {
                        Text(size.aspectLabel)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                }
                .frame(width: screenSize.width, height: screenSize.height)
            Rectangle()
                .fill(Color.primary.opacity(0.3))
                .frame(width: 3, height: 5)
            Capsule()
                .fill(Color.primary.opacity(0.3))
                .frame(width: max(14, screenSize.width * 0.28), height: 2.5)
        }
        .frame(width: maxWidth, height: maxHeight + 8, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
