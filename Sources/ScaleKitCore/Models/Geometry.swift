import Foundation

/// A width and height in pixels or points.
public struct PixelSize: Codable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double {
        height == 0 ? 0 : Double(width) / Double(height)
    }

    public var area: Int { width * height }

    public var description: String { "\(width) × \(height)" }

    /// True when both sizes have the same shape within `tolerance` (relative).
    public func hasSameAspect(as other: PixelSize, tolerance: Double = 0.015) -> Bool {
        guard other.aspectRatio > 0, aspectRatio > 0 else { return false }
        return abs(aspectRatio - other.aspectRatio) / other.aspectRatio <= tolerance
    }

    /// Marketing-style aspect label such as "21:9" or "16:9".
    public var aspectLabel: String {
        let ratio = aspectRatio
        let known: [(String, Double)] = [
            ("32:9", 32.0 / 9), ("21:9", 2.37), ("16:9", 16.0 / 9), ("16:10", 1.6),
            ("3:2", 1.5), ("4:3", 4.0 / 3), ("5:4", 1.25),
        ]
        for (label, value) in known where abs(ratio - value) / value < 0.03 {
            return label
        }
        return String(format: "%.2f:1", ratio)
    }
}

/// Physical panel size reported by the display's EDID.
public struct PhysicalSize: Codable, Hashable, Sendable {
    public var widthMM: Double
    public var heightMM: Double

    public init(widthMM: Double, heightMM: Double) {
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    public var diagonalInches: Double {
        (widthMM * widthMM + heightMM * heightMM).squareRoot() / 25.4
    }

    public var description: String {
        String(format: "%.0f × %.0f mm (%.1f″)", widthMM, heightMM, diagonalInches)
    }
}

/// A rectangle in the global display coordinate space (points).
public struct DisplayBounds: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var size: PixelSize { PixelSize(width: Int(width.rounded()), height: Int(height.rounded())) }
}
