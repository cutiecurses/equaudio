// Renders EquAudio's application icon with CoreGraphics and packs it into an .icns file.
//
//   swift scripts/make-icon.swift <out.icns> [--png <preview.png>]
//
// Every iconset size (16 ... 1024 px) is drawn from vector geometry rather than downsampled from one
// bitmap, and the smallest sizes use a simplified design so they stay legible in Finder lists and
// the menu bar. build.sh caches the result keyed by this file's checksum: editing the script
// re-renders the icon on the next build.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

// MARK: - Design (1024-pt grid, origin bottom-left)

/// sRGB colour from 8-bit components.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// macOS icon grid: an 824-pt body centred on the 1024-pt canvas leaves room for its shadow.
let canvas: CGFloat = 1024
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Bar fill: teal -> violet, left to right.
let accentColors = [rgb(226, 160, 170), rgb(183, 110, 121), rgb(150, 84, 102)]
let accentLocations: [CGFloat] = [0, 0.45, 1]

/// Bars of a stylised equaliser/waveform, centred on a horizontal axis.
struct BarLayout {
    /// Bar heights as fractions of `maxHeight`, left to right.
    var heights: [CGFloat]
    var barWidth: CGFloat
    var gap: CGFloat
    var maxHeight: CGFloat
    /// Blurred light around the bars (it only muddies tiny renditions).
    var glow: Bool
    /// Rim light, sheen and axis line (sub-pixel at tiny sizes).
    var detail: Bool

    /// Full artwork from 64 px up; fewer, bolder bars below that. The small layouts use whole
    /// pixels at their target size (64 grid units per pixel at 16 px, 32 at 32 px).
    static func forPixelSize(_ pixels: Int) -> BarLayout {
        switch pixels {
        case ..<24:
            return BarLayout(heights: [0.5, 1.0, 0.75], barWidth: 128, gap: 64, maxHeight: 512, glow: false, detail: false)
        case ..<48:
            return BarLayout(heights: [0.45, 0.78, 1.0, 0.78, 0.45], barWidth: 96, gap: 32, maxHeight: 576, glow: false, detail: false)
        default:
            return BarLayout(heights: [0.30, 0.56, 0.86, 1.0, 0.78, 0.50, 0.30], barWidth: 58, gap: 30, maxHeight: 548, glow: true, detail: true)
        }
    }

    /// Capsule rectangles, centred horizontally on the canvas and vertically on `axisY`, with edges
    /// snapped to the pixel grid of the target size so small renditions stay crisp.
    func barRects(axisY: CGFloat, pixels: Int) -> [CGRect] {
        let unit = canvas / CGFloat(pixels)
        func snap(_ v: CGFloat) -> CGFloat { (v / unit).rounded() * unit }
        let count = CGFloat(heights.count)
        let totalWidth = count * barWidth + (count - 1) * gap
        var x = (canvas - totalWidth) / 2
        return heights.map { fraction in
            let h = max(barWidth, fraction * maxHeight)
            defer { x += barWidth + gap }
            let minX = snap(x), maxX = snap(x + barWidth)
            let minY = snap(axisY - h / 2), maxY = snap(axisY + h / 2)
            return CGRect(x: minX, y: minY, width: max(unit, maxX - minX), height: max(unit, maxY - minY))
        }
    }
}

/// Superellipse |x|^n + |y|^n = 1 with n = 5: within a pixel of Apple's continuous-corner icon shape.
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5, segments: Int = 2048) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0..<segments {
        let t = CGFloat(i) / CGFloat(segments) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(x: rect.midX + a * copysign(pow(abs(c), 2 / n), c),
                            y: rect.midY + b * copysign(pow(abs(s), 2 / n), s))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func capsulesPath(_ rects: [CGRect]) -> CGPath {
    let path = CGMutablePath()
    for r in rects {
        path.addRoundedRect(in: r, cornerWidth: r.width / 2, cornerHeight: r.width / 2)
    }
    return path
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

// MARK: - Rendering

enum IconError: Error, CustomStringConvertible {
    case context(Int), encode(String), iconutil(Int32)
    var description: String {
        switch self {
        case .context(let px): return "cannot create a \(px) px bitmap context"
        case .encode(let path): return "cannot write PNG \(path)"
        case .iconutil(let status): return "iconutil failed with status \(status)"
        }
    }
}

func makeContext(_ pixels: Int) throws -> CGContext {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError.context(pixels)
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

/// Bars filled with the accent gradient on a transparent canvas (also the source of the glow).
func renderBars(_ layout: BarLayout, rects: [CGRect], pixels: Int) throws -> CGImage {
    let ctx = try makeContext(pixels)
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)
    let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
    ctx.addPath(capsulesPath(rects))
    ctx.clip()
    ctx.drawLinearGradient(linearGradient(accentColors, accentLocations),
                           start: CGPoint(x: union.minX, y: union.midY),
                           end: CGPoint(x: union.maxX, y: union.midY), options: [])
    if layout.detail {
        // Soft vertical sheen: slightly lighter towards the top, like light catching rounded glass.
        let sheen = linearGradient([rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0), rgb(0, 0, 0, 0.10)], [0, 0.55, 1])
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: union.maxY), end: CGPoint(x: 0, y: union.minY), options: [])
    }
    return ctx.makeImage()!
}

/// Gaussian-blurred copy of `image` (same extent) for the glow.
func blurred(_ image: CGImage, sigma: CGFloat) -> CGImage {
    let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let blurredImage = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: extent)
    // clampedToExtent() repeats edge pixels; the bars never touch the edges, so that is transparent.
    let context = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
    return context.createCGImage(blurredImage, from: extent)!
}

/// Draws the complete icon at `pixels` x `pixels`.
func renderIcon(pixels: Int) throws -> CGImage {
    let layout = BarLayout.forPixelSize(pixels)
    let scale = CGFloat(pixels) / canvas
    let ctx = try makeContext(pixels)
    ctx.scaleBy(x: scale, y: scale)
    let body = squirclePath(in: bodyRect)

    // Drop shadow beneath the body (shadow metrics are in device pixels, hence `scale`).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: rgb(0, 0, 0, 0.45))
    ctx.addPath(body)
    ctx.setFillColor(rgb(24, 20, 22))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: deep blue-slate, lighter at the top, with a faint indigo ambience behind the bars.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(linearGradient([rgb(60, 50, 55), rgb(38, 32, 35), rgb(20, 17, 19)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.minY), options: [])
    let ambience = linearGradient([rgb(183, 110, 121, 0.22), rgb(226, 160, 170, 0.06), rgb(226, 160, 170, 0)], [0, 0.6, 1])
    ctx.drawRadialGradient(ambience, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 440, options: [])
    if layout.detail {
        // Glassy sheen over the upper half.
        ctx.drawLinearGradient(linearGradient([rgb(255, 255, 255, 0.07), rgb(255, 255, 255, 0)], [0, 1]),
                               start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.midY + 40), options: [])
    }
    ctx.restoreGState()

    let axisY: CGFloat = 512
    let rects = layout.barRects(axisY: axisY, pixels: pixels)

    if layout.detail {
        // Faint signal axis the waveform sits on, fading out towards the rim.
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let axis = CGRect(x: bodyRect.minX + 70, y: axisY - 2, width: bodyRect.width - 140, height: 4)
        ctx.clip(to: axis)
        ctx.drawLinearGradient(linearGradient([rgb(226, 160, 170, 0), rgb(226, 160, 170, 0.22), rgb(183, 110, 121, 0.22), rgb(183, 110, 121, 0)],
                                              [0, 0.3, 0.7, 1]),
                               start: CGPoint(x: axis.minX, y: axisY), end: CGPoint(x: axis.maxX, y: axisY), options: [])
        ctx.restoreGState()
    }

    let bars = try renderBars(layout, rects: rects, pixels: pixels)
    let fullRect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    if layout.glow {
        // Two glow passes: a wide, faint halo and a tighter, brighter bloom.
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.setBlendMode(.screen)
        ctx.setAlpha(0.40)
        ctx.draw(blurred(bars, sigma: 64 * scale), in: fullRect)
        ctx.setAlpha(0.70)
        ctx.draw(blurred(bars, sigma: 18 * scale), in: fullRect)
        ctx.restoreGState()
    }
    ctx.draw(bars, in: fullRect)

    if layout.detail {
        // Rim light: a hairline inside the edge, brighter at the top.
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.addPath(body)
        ctx.setLineWidth(5)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(linearGradient([rgb(255, 255, 255, 0.22), rgb(255, 255, 255, 0.04)], [0, 1]),
                               start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.minY), options: [])
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw IconError.encode(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.encode(url.path) }
}

// MARK: - Main

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <out.icns> [--png <preview.png>]\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var outputPath: String?
var previewPath: String?
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--png":
        guard !arguments.isEmpty else { usage() }
        previewPath = arguments.removeFirst()
    case "-h", "--help":
        print("usage: swift scripts/make-icon.swift <out.icns> [--png <preview.png>]")
        exit(0)
    default:
        guard outputPath == nil, !argument.hasPrefix("-") else { usage() }
        outputPath = argument
    }
}
guard let outputPath else { usage() }

do {
    let fm = FileManager.default
    let outputURL = URL(fileURLWithPath: outputPath)
    let work = fm.temporaryDirectory.appendingPathComponent("equaudio-icon-\(UUID().uuidString)", isDirectory: true)
    let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    // Point sizes at 1x and 2x, named the way iconutil expects.
    var rendered: [Int: CGImage] = [:]
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let pixels = points * factor
            let image = try rendered[pixels] ?? renderIcon(pixels: pixels)
            rendered[pixels] = image
            let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
            try writePNG(image, to: iconset.appendingPathComponent(name))
        }
    }
    if let previewPath {
        try writePNG(rendered[1024]!, to: URL(fileURLWithPath: previewPath))
    }

    try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", outputURL.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw IconError.iconutil(iconutil.terminationStatus) }
    print("Wrote \(outputURL.path)")
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
