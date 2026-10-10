import AppKit
import ScaleKitCore
import SwiftUI

/// Renders ScaleKit's own windows to PNG files for the README:
/// `ScaleKit --render-screenshots <directory>`.
///
/// Read-only: it refreshes the display list and draws views offscreen. It
/// never starts launch recovery, event monitoring or any display change, and
/// it needs no screen-recording permission because it only draws its own views.
@MainActor
enum ScreenshotRenderer {
    static let argument = "--render-screenshots"

    static func directoryArgument() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(model: AppModel, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.refreshNow()
        model.selectTarget(ScalingTarget(percent: 125))
        let title = "ScaleKit — \(model.selectedDisplay?.displayName ?? "Display")"

        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            render(MainView().environment(model), size: CGSize(width: 1040, height: 760), appearance: appearance,
                   title: title, to: directory.appendingPathComponent("main-\(suffix).png"))
        }
        render(PreviewWindow().environment(model), size: CGSize(width: 1020, height: 680), appearance: .darkAqua,
               title: "Scaling Preview", to: directory.appendingPathComponent("preview-dark.png"))
        render(AdvancedWindow().environment(model), size: CGSize(width: 980, height: 660), appearance: .darkAqua,
               title: "Advanced Display Information", to: directory.appendingPathComponent("advanced-dark.png"))
        render(SettingsView().environment(model), size: CGSize(width: 480, height: 330), appearance: .darkAqua,
               title: "Settings", to: directory.appendingPathComponent("settings-dark.png"))
        print("Rendered screenshots to \(directory.path)")
    }

    // MARK: - Rendering

    private static let scale: CGFloat = 2

    private static func render<V: View>(
        _ view: V, size: CGSize, appearance: NSAppearance.Name, title: String, to url: URL
    ) {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        // Let SwiftUI lay out, load and settle.
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = size
        var content: CGImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            content = rep.cgImage
        }
        window.orderOut(nil)
        guard let content else { return }
        let dark = appearance == .darkAqua
        guard let framed = frame(content, contentSize: size, title: title, dark: dark),
              let data = NSBitmapImageRep(cgImage: framed).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }

    /// The content inside a macOS-style window (title bar, traffic lights,
    /// rounded corners, shadow) on a soft gradient.
    private static func frame(_ content: CGImage, contentSize: CGSize, title: String, dark: Bool) -> CGImage? {
        let titleBar: CGFloat = 32
        let margin: CGFloat = 72
        let windowSize = CGSize(width: contentSize.width, height: contentSize.height + titleBar)
        let canvas = CGSize(width: windowSize.width + margin * 2, height: windowSize.height + margin * 2)
        let pixels = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        guard let context = CGContext(
            data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        // Background gradient.
        let colors = dark
            ? [CGColor(srgbRed: 0.10, green: 0.09, blue: 0.24, alpha: 1), CGColor(srgbRed: 0.30, green: 0.13, blue: 0.45, alpha: 1),
               CGColor(srgbRed: 0.05, green: 0.27, blue: 0.45, alpha: 1)]
            : [CGColor(srgbRed: 0.80, green: 0.86, blue: 1.0, alpha: 1), CGColor(srgbRed: 0.93, green: 0.83, blue: 1.0, alpha: 1),
               CGColor(srgbRed: 0.78, green: 0.95, blue: 0.98, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                     locations: [0, 0.55, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height),
                                       end: CGPoint(x: canvas.width, y: 0), options: [])
        }

        let windowRect = CGRect(origin: CGPoint(x: margin, y: margin), size: windowSize)
        let path = CGPath(roundedRect: windowRect, cornerWidth: 12, cornerHeight: 12, transform: nil)

        // Shadow.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -18), blur: 48,
                          color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.3))
        context.addPath(path)
        context.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.98, alpha: 1))
        context.fillPath()
        context.restoreGState()

        // Window contents, clipped to the rounded corners.
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(content, in: CGRect(x: windowRect.minX, y: windowRect.minY,
                                         width: contentSize.width, height: contentSize.height))
        let barRect = CGRect(x: windowRect.minX, y: windowRect.maxY - titleBar, width: windowRect.width, height: titleBar)
        context.setFillColor(dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1)
                                  : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        context.fill(barRect)
        context.setFillColor(CGColor(gray: dark ? 0 : 0.75, alpha: dark ? 0.6 : 1))
        context.fill(CGRect(x: barRect.minX, y: barRect.minY - 0.5, width: barRect.width, height: 0.5))
        context.restoreGState()

        // Traffic lights.
        let lights = [
            CGColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1),
            CGColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1),
        ]
        for (index, color) in lights.enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: windowRect.minX + 14 + CGFloat(index) * 20,
                                           y: barRect.midY - 6, width: 12, height: 12))
        }

        // Title.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1),
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let textSize = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: barRect.midX - textSize.width / 2, y: barRect.midY - textSize.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        // Thin outline.
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.12 : 0.1))
        context.setLineWidth(1)
        context.strokePath()
        return context.makeImage()
    }
}
