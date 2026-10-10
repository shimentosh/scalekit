#!/usr/bin/env swift
// make-icon.swift — renders the ScaleKit app icon with CoreGraphics.
//
// Usage:
//   swift scripts/make-icon.swift <work-dir> [--icns <output.icns>]
//
// Writes <work-dir>/AppIcon.iconset/ (every size macOS asks for, 16–1024 px),
// a full-size preview at <work-dir>/AppIcon-1024.png, and then runs
// `iconutil -c icns` to produce the .icns (default: <work-dir>/AppIcon.icns).
// Keep <work-dir> outside the repository; only the .icns is checked in:
//
//   swift scripts/make-icon.swift "$TMPDIR/scalekit-icon" --icns Resources/AppIcon.icns
//
// Design: follows the macOS (Big Sur and later) icon grid — an 824/1024
// continuous-corner "squircle" body centred on the canvas, a gentle
// top-to-bottom gradient and a soft drop shadow. The motif is an ultrawide
// (21:9) monitor whose screen shows a large, crisp "Aa": a sharper, larger
// interface. Small sizes (16 and 32 pt) get simplified, pixel-snapped artwork
// so they stay legible instead of being down-sampled from the 1024 master.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var icnsOutput: URL?
if let flag = arguments.firstIndex(of: "--icns") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("error: --icns needs a path\n".utf8))
        exit(2)
    }
    icnsOutput = URL(fileURLWithPath: arguments[flag + 1])
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 1 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <work-dir> [--icns <output.icns>]\n".utf8))
    exit(2)
}
let workDir = URL(fileURLWithPath: arguments[0], isDirectory: true)
let iconset = workDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icns = icnsOutput ?? workDir.appendingPathComponent("AppIcon.icns")

// MARK: - Palette

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ])!
}

enum Palette {
    // Squircle body: cool, bright aluminium.
    static let bodyTop = rgb(0xFBFCFE)
    static let bodyBottom = rgb(0xD9DEE8)
    static let bodyEdge = rgb(0x000000, 0.10)
    // Monitor.
    static let bezelTop = rgb(0x2A2E37)
    static let bezelBottom = rgb(0x111318)
    static let screenTop = rgb(0x3D7BFF)
    static let screenBottom = rgb(0x6A3DF0)
    static let glyph = rgb(0xFFFFFF)
    static let standTop = rgb(0xC9CED8)
    static let standBottom = rgb(0x9097A5)
}

// MARK: - Geometry

/// A rounded rectangle with continuous (curvature-matched) corners, the shape
/// Apple uses for app icons. Coefficients from the iOS 7+ squircle reconstruction.
func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    // Each corner: its point, a unit vector back along the incoming edge, and one along the outgoing edge.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    for (index, (c, e1, e2)) in corners.enumerated() {
        func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (a * e1.dx + b * e2.dx) * r, y: c.y + (a * e1.dy + b * e2.dy) * r)
        }
        if index == 0 { path.move(to: p(1.52866483, 0)) } else { path.addLine(to: p(1.52866483, 0)) }
        path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
        path.addLine(to: p(0.63149399, 0.07491100))
        path.addCurve(to: p(0.07491100, 0.63149399), control1: p(0.37282392, 0.16905899), control2: p(0.16906013, 0.37282401))
        path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840701), control2: p(0, 1.08849299))
    }
    path.closeSubpath()
    return path
}

/// Outline of `text` set in `font`, with the glyph origin at (0, 0).
func textPath(_ text: String, font: CTFont, tracking: CGFloat = 0) -> CGPath {
    let attributed = NSAttributedString(
        string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, .kern: tracking])
    let line = CTLineCreateWithAttributedString(attributed)
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = attributes[kCTFontAttributeName as String] as! CTFont
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for i in 0..<count {
            if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                path.addPath(glyph, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
    }
    return path
}

/// Bends a path so it reads as a curved ultrawide panel seen head-on: the
/// ends stay full height while the middle is pinched by `amount` (a fraction).
func curved(_ path: CGPath, around rect: CGRect, amount: CGFloat) -> CGPath {
    guard amount > 0 else { return path }
    func warp(_ p: CGPoint) -> CGPoint {
        let u = (p.x - rect.midX) / (rect.width / 2)
        let squeeze = 1 - amount * max(0, 1 - u * u)
        return CGPoint(x: p.x, y: rect.midY + (p.y - rect.midY) * squeeze)
    }
    let out = CGMutablePath()
    var current = CGPoint.zero, subpathStart = CGPoint.zero  // unwarped coordinates
    // Straight edges are subdivided so that they bend too.
    func line(to end: CGPoint) {
        for step in 1...32 {
            let t = CGFloat(step) / 32
            out.addLine(to: warp(CGPoint(x: current.x + (end.x - current.x) * t, y: current.y + (end.y - current.y) * t)))
        }
        current = end
    }
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint:
            current = e.points[0]; subpathStart = current
            out.move(to: warp(current))
        case .addLineToPoint:
            line(to: e.points[0])
        case .addQuadCurveToPoint:
            out.addQuadCurve(to: warp(e.points[1]), control: warp(e.points[0]))
            current = e.points[1]
        case .addCurveToPoint:
            out.addCurve(to: warp(e.points[2]), control1: warp(e.points[0]), control2: warp(e.points[1]))
            current = e.points[2]
        case .closeSubpath:
            line(to: subpathStart)
            out.closeSubpath()
        @unknown default: break
        }
    }
    return out
}

func systemFont(size: CGFloat, weight: NSFont.Weight, rounded: Bool = false) -> CTFont {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
        font = NSFont(descriptor: descriptor, size: size) ?? font
    }
    return font as CTFont
}

extension CGContext {
    func fillLinearGradient(_ path: CGPath, colors: [CGColor], from start: CGPoint, to end: CGPoint, locations: [CGFloat]? = nil) {
        guard let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations) else { return }
        saveGState()
        addPath(path)
        clip()
        drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }
}

// MARK: - Artwork

/// Level of detail, chosen by the size in points the image is displayed at.
enum Detail { case small, medium, full }

/// Draws the icon in a 1024 × 1024 coordinate space (origin bottom-left).
/// `pixelsPerUnit` lets small renditions snap edges to whole pixels.
func drawIcon(in ctx: CGContext, detail: Detail, pixelsPerUnit: CGFloat) {
    func snap(_ v: CGFloat) -> CGFloat {
        detail == .full ? v : (v * pixelsPerUnit).rounded() / pixelsPerUnit
    }
    func snapRect(_ r: CGRect) -> CGRect {
        let x0 = snap(r.minX), y0 = snap(r.minY), x1 = snap(r.maxX), y1 = snap(r.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // Body: the Big Sur grid's 824 × 824 squircle, centred, radius ≈ 185.4.
    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = continuousRect(bodyRect, radius: 185.4)

    // Soft drop shadow beneath the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * pixelsPerUnit), blur: 28 * pixelsPerUnit, color: rgb(0x000000, 0.30))
    ctx.addPath(body)
    ctx.setFillColor(Palette.bodyBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.fillLinearGradient(
        body, colors: [Palette.bodyTop, Palette.bodyBottom],
        from: CGPoint(x: 512, y: bodyRect.maxY), to: CGPoint(x: 512, y: bodyRect.minY))

    // Hairline edge so the light body holds its shape on light backgrounds.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.addPath(body)
    ctx.setStrokeColor(detail == .full ? Palette.bodyEdge : rgb(0x000000, 0.16))
    ctx.setLineWidth(detail == .full ? 4 : 1 / pixelsPerUnit)
    ctx.strokePath()
    ctx.restoreGState()

    // Monitor geometry. Small sizes enlarge it and thicken the bezel so the
    // screen stays a clear, solid shape.
    let faceWidth: CGFloat, bezel: CGFloat, bend: CGFloat
    switch detail {
    case .full: faceWidth = 700; bezel = 16; bend = 0.045
    case .medium: faceWidth = 736; bezel = 32; bend = 0
    case .small: faceWidth = 768; bezel = 64; bend = 0
    }
    let faceHeight = faceWidth * 9 / 21
    let neckHeight: CGFloat = detail == .small ? 64 : 70
    let footHeight: CGFloat = detail == .small ? 64 : 28
    let total = faceHeight + neckHeight + footHeight
    let faceBottom = 512 - total / 2 + neckHeight + footHeight + (detail == .full ? 10 : 0)
    let face = snapRect(CGRect(x: 512 - faceWidth / 2, y: faceBottom, width: faceWidth, height: faceHeight))
    let screen = snapRect(face.insetBy(dx: bezel, dy: bezel))

    // Stand: a brushed-aluminium neck and foot.
    let neckWidth: CGFloat = detail == .small ? 128 : 100
    let neck = snapRect(CGRect(x: 512 - neckWidth / 2, y: face.minY - neckHeight - 4, width: neckWidth, height: neckHeight + 24))
    let footWidth: CGFloat = detail == .small ? 384 : 312
    let foot = snapRect(CGRect(x: 512 - footWidth / 2, y: neck.minY - footHeight + 4, width: footWidth, height: footHeight))
    ctx.fillLinearGradient(
        CGPath(rect: neck, transform: nil), colors: [Palette.standBottom, Palette.standTop, Palette.standBottom],
        from: CGPoint(x: neck.minX, y: 0), to: CGPoint(x: neck.maxX, y: 0), locations: [0, 0.5, 1])
    if detail == .full {
        // Shadow cast by the panel onto the top of the neck.
        let shade = CGRect(x: neck.minX, y: face.minY - 26, width: neck.width, height: 26)
        ctx.fillLinearGradient(
            CGPath(rect: shade, transform: nil), colors: [rgb(0x000000, 0.22), rgb(0x000000, 0)],
            from: CGPoint(x: 0, y: shade.maxY), to: CGPoint(x: 0, y: shade.minY))
    }
    if detail == .full {
        // Contact shadow that grounds the foot on the body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * pixelsPerUnit), blur: 14 * pixelsPerUnit, color: rgb(0x0B1530, 0.25))
        ctx.addPath(continuousRect(foot, radius: min(foot.height / 2, 14)))
        ctx.setFillColor(Palette.standBottom)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.fillLinearGradient(
        continuousRect(foot, radius: min(foot.height / 2, 14)), colors: [Palette.standTop, Palette.standBottom],
        from: CGPoint(x: 512, y: foot.maxY), to: CGPoint(x: 512, y: foot.minY))

    // Bezel, with a soft contact shadow on the body.
    let faceRadius: CGFloat = detail == .full ? 28 : (detail == .medium ? 34 : 40)
    let facePath = curved(continuousRect(face, radius: faceRadius), around: face, amount: bend)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16 * pixelsPerUnit), blur: 34 * pixelsPerUnit, color: rgb(0x0B1530, 0.30))
    ctx.addPath(facePath)
    ctx.setFillColor(Palette.bezelBottom)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.fillLinearGradient(
        facePath, colors: [Palette.bezelTop, Palette.bezelBottom],
        from: CGPoint(x: 512, y: face.maxY), to: CGPoint(x: 512, y: face.minY))

    // Screen: a vivid blue-to-violet panel.
    let screenRadius = max(4, faceRadius - bezel * 0.75)
    let screenPath = curved(continuousRect(screen, radius: screenRadius), around: face, amount: bend)
    ctx.fillLinearGradient(
        screenPath, colors: [Palette.screenTop, Palette.screenBottom],
        from: CGPoint(x: screen.minX, y: screen.maxY), to: CGPoint(x: screen.maxX, y: screen.minY))

    if detail == .full {
        ctx.saveGState()
        ctx.addPath(screenPath)
        ctx.clip()
        // A faint diagonal sheen across the left of the glass.
        let sheen = CGMutablePath()
        sheen.move(to: CGPoint(x: screen.minX, y: screen.maxY + 20))
        sheen.addLine(to: CGPoint(x: screen.minX + screen.width * 0.50, y: screen.maxY + 20))
        sheen.addLine(to: CGPoint(x: screen.minX + screen.width * 0.30, y: screen.minY - 20))
        sheen.addLine(to: CGPoint(x: screen.minX, y: screen.minY - 20))
        sheen.closeSubpath()
        ctx.addPath(sheen)
        ctx.setFillColor(rgb(0xFFFFFF, 0.08))
        ctx.fillPath()
        // Corner marks: the content fills the panel edge to edge.
        let inset: CGFloat = 26, arm: CGFloat = 38
        let marks = CGMutablePath()
        for (cx, sx) in [(screen.minX + inset, CGFloat(1)), (screen.maxX - inset, CGFloat(-1))] {
            for (cy, sy) in [(screen.minY + inset, CGFloat(1)), (screen.maxY - inset, CGFloat(-1))] {
                marks.move(to: CGPoint(x: cx, y: cy + sy * arm))
                marks.addLine(to: CGPoint(x: cx, y: cy))
                marks.addLine(to: CGPoint(x: cx + sx * arm, y: cy))
            }
        }
        ctx.addPath(curved(marks, around: face, amount: bend))
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()

        // Hairline highlight along the top of the bezel.
        ctx.saveGState()
        ctx.addPath(facePath)
        ctx.clip()
        ctx.addPath(curved(continuousRect(face.offsetBy(dx: 0, dy: -3), radius: faceRadius), around: face, amount: bend))
        ctx.addPath(facePath)
        ctx.setFillColor(rgb(0xFFFFFF, 0.18))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // "Aa" — large and crisp, optically centred on the screen. The 16 pt
    // rendition is too small for letters, so its screen stays clean.
    guard detail != .small else { return }
    let fontSize = screen.height * (detail == .full ? 1.0 : 1.04)
    let glyphs = textPath("Aa", font: systemFont(size: fontSize, weight: detail == .full ? .semibold : .bold), tracking: -fontSize * 0.01)
    let bounds = glyphs.boundingBoxOfPath
    var place = CGAffineTransform(translationX: snap(screen.midX - bounds.midX), y: snap(screen.midY - bounds.midY))
    if let positioned = glyphs.copy(using: &place) {
        ctx.saveGState()
        if detail == .full {
            ctx.setShadow(offset: CGSize(width: 0, height: -4 * pixelsPerUnit), blur: 14 * pixelsPerUnit, color: rgb(0x14082E, 0.35))
        }
        ctx.addPath(positioned)
        ctx.setFillColor(Palette.glyph)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - Rendering

func render(pixels: Int, points: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create a \(pixels)px bitmap context") }
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let detail: Detail = points <= 16 ? .small : (points <= 32 ? .medium : .full)
    drawIcon(in: ctx, detail: detail, pixelsPerUnit: scale)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let renditions: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]

do {
    let fm = FileManager.default
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for rendition in renditions {
        let pixels = rendition.points * rendition.scale
        try writePNG(render(pixels: pixels, points: rendition.points), to: iconset.appendingPathComponent("\(rendition.name).png"))
    }
    try writePNG(render(pixels: 1024, points: 512), to: workDir.appendingPathComponent("AppIcon-1024.png"))
    print("Wrote \(renditions.count) renditions to \(iconset.path)")

    try fm.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("error: iconutil failed with status \(iconutil.terminationStatus)\n".utf8))
        exit(1)
    }
    print("Wrote \(icns.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
