import AppKit
import EquAudioKit
import SwiftUI

enum VizMode: Int, CaseIterable, Identifiable {
    case spectrum, impact, scope, radial, waterfall
    var id: Int { rawValue }
    var title: String { ["Spectrum", "Impact", "Scope", "Radial", "Waterfall"][rawValue] }
    var caption: String {
        ["live output, peak holds",
         "input vs output: what your EQ does",
         "waveform + stereo width",
         "reacts to the bass",
         "frequency over time"][rawValue]
    }
}

// MARK: - Colour helpers

private func components(_ c: Color) -> (Double, Double, Double) {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
    return (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
}

private func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let x = components(a), y = components(b), t = min(max(t, 0), 1)
    return Color(.sRGB, red: x.0 + (y.0 - x.0) * t, green: x.1 + (y.1 - x.1) * t, blue: x.2 + (y.2 - x.2) * t)
}

/// Flat heat palette for the spectrogram: background -> panel tone -> accent -> text.
private func heatPalette(_ steps: Int = 48) -> [Color] {
    (0..<steps).map { i in
        let t = Double(i) / Double(steps - 1)
        if t < 0.35 { return mix(UI.bg, UI.raised, t / 0.35) }
        if t < 0.75 { return mix(UI.raised, UI.accent, (t - 0.35) / 0.4) }
        return mix(UI.accent, UI.text, (t - 0.75) / 0.25)
    }
}

// MARK: - Drawing

enum VizDraw {
    static func draw(_ mode: VizMode, _ ctx: GraphicsContext, _ size: CGSize, _ a: Analyzer) {
        switch mode {
        case .spectrum: spectrum(ctx, size, a)
        case .impact: impact(ctx, size, a)
        case .scope: scope(ctx, size, a)
        case .radial: radial(ctx, size, a)
        case .waterfall: waterfall(ctx, size, a)
        }
    }

    private static func freqLabel(_ f: Float) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }

    /// x position (0...1) of a frequency along the log band axis.
    private static func position(of f: Float, _ a: Analyzer) -> CGFloat {
        guard let first = a.bandFrequencies.first, let last = a.bandFrequencies.last, last > first else { return 0 }
        return CGFloat(log(f / first) / log(last / first))
    }

    private static func grid(_ ctx: GraphicsContext, _ size: CGSize, _ a: Analyzer, bottom: CGFloat) {
        for k in 1...3 {
            var line = Path(); let y = (size.height - bottom) * CGFloat(k) / 4
            line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(line, with: .color(UI.raised.opacity(0.7)), lineWidth: 1)
        }
        for f: Float in [50, 100, 250, 500, 1000, 2500, 5000, 10000] {
            let x = position(of: f, a) * size.width
            ctx.draw(Text(freqLabel(f)).font(UI.font(10)).foregroundColor(UI.muted), at: CGPoint(x: min(max(x, 12), size.width - 12), y: size.height - 8))
        }
    }

    // 1. Spectrum bars with peak holds; bass region in full accent, highs fade back.
    static func spectrum(_ ctx: GraphicsContext, _ size: CGSize, _ a: Analyzer) {
        let n = Analyzer.bandCount, bottom: CGFloat = 20, h = size.height - bottom
        grid(ctx, size, a, bottom: bottom)
        let gap: CGFloat = 2.5, w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
        for i in 0..<n {
            let x = CGFloat(i) * (w + gap), bar = max(3, h * CGFloat(a.bands[i]))
            let fade = a.bandFrequencies[i] < 150 ? 1.0 : 0.86 - 0.32 * Double(i) / Double(n)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: h - bar, width: w, height: bar), cornerRadius: min(w / 2, 3)), with: .color(UI.accent.opacity(fade)))
            let cap = h * CGFloat(a.peaks[i])
            ctx.fill(Path(roundedRect: CGRect(x: x, y: h - cap - 4, width: w, height: 2.5), cornerRadius: 1), with: .color(UI.text.opacity(0.85)))
        }
    }

    // 2. Impact: input outline vs output fill, with the measured change per region on top.
    static func impact(_ ctx: GraphicsContext, _ size: CGSize, _ a: Analyzer) {
        let n = Analyzer.bandCount, bottom: CGFloat = 20, h = size.height - bottom - 34
        let top: CGFloat = 34
        grid(ctx, CGSize(width: size.width, height: size.height - 34 + 34), a, bottom: bottom)
        func path(_ v: [Float]) -> Path {
            var p = Path()
            for i in 0..<n {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1), y: top + h * (1 - CGFloat(v[i])))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            return p
        }
        var fill = path(a.outputCurve)
        fill.addLine(to: CGPoint(x: size.width, y: top + h)); fill.addLine(to: CGPoint(x: 0, y: top + h)); fill.closeSubpath()
        ctx.fill(fill, with: .color(UI.accent.opacity(0.22)))
        ctx.stroke(path(a.outputCurve), with: .color(UI.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        ctx.stroke(path(a.inputCurve), with: .color(UI.muted), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [5, 4]))
        // measured effect per region
        func chip(_ title: String, _ db: Float, _ x: CGFloat) {
            let text = String(format: "%@ %+.1f dB", title, db)
            ctx.draw(Text(text).font(UI.font(12)).foregroundColor(abs(db) < 0.5 ? UI.muted : UI.text), at: CGPoint(x: x, y: 12), anchor: .leading)
        }
        chip("BASS", a.delta.bass, 6)
        chip("MIDS", a.delta.mid, size.width * 0.36)
        chip("HIGHS", a.delta.high, size.width * 0.68)
        ctx.draw(Text("— output").font(UI.font(10)).foregroundColor(UI.accent), at: CGPoint(x: size.width - 8, y: size.height - 26), anchor: .trailing)
        ctx.draw(Text("- - input").font(UI.font(10)).foregroundColor(UI.muted), at: CGPoint(x: size.width - 8, y: size.height - 40), anchor: .trailing)
    }

    // 3. Scope: waveform on top, stereo vectorscope (goniometer) below.
    static func scope(_ ctx: GraphicsContext, _ size: CGSize, _ a: Analyzer) {
        let waveH = size.height * 0.34
        var mid = Path(); mid.move(to: CGPoint(x: 0, y: waveH / 2)); mid.addLine(to: CGPoint(x: size.width, y: waveH / 2))
        ctx.stroke(mid, with: .color(UI.raised), lineWidth: 1)
        var wave = Path()
        let n = a.left.count
        for i in 0..<n {
            let v = CGFloat((a.left[i] + a.right[i]) * 0.5)
            let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1), y: waveH / 2 - v * waveH * 0.46)
            i == 0 ? wave.move(to: pt) : wave.addLine(to: pt)
        }
        ctx.stroke(wave, with: .color(UI.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        ctx.draw(Text("WAVEFORM").font(UI.font(10)).foregroundColor(UI.muted), at: CGPoint(x: 6, y: 8), anchor: .leading)

        let areaTop = waveH + 14, side = min(size.width, size.height - areaTop) - 8
        let c = CGPoint(x: size.width / 2, y: areaTop + (size.height - areaTop) / 2), r = side / 2
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(UI.raised), lineWidth: 1)
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r / 2, y: c.y - r / 2, width: r, height: r)), with: .color(UI.raised.opacity(0.6)), lineWidth: 1)
        var axes = Path()
        axes.move(to: CGPoint(x: c.x, y: c.y - r)); axes.addLine(to: CGPoint(x: c.x, y: c.y + r))
        axes.move(to: CGPoint(x: c.x - r, y: c.y)); axes.addLine(to: CGPoint(x: c.x + r, y: c.y))
        axes.move(to: CGPoint(x: c.x - r * 0.707, y: c.y + r * 0.707)); axes.addLine(to: CGPoint(x: c.x + r * 0.707, y: c.y - r * 0.707))
        axes.move(to: CGPoint(x: c.x - r * 0.707, y: c.y - r * 0.707)); axes.addLine(to: CGPoint(x: c.x + r * 0.707, y: c.y + r * 0.707))
        ctx.stroke(axes, with: .color(UI.raised.opacity(0.7)), lineWidth: 1)
        for (t, p) in [("MONO", CGPoint(x: c.x, y: c.y - r - 6)), ("L", CGPoint(x: c.x - r * 0.72, y: c.y - r * 0.72 - 8)), ("R", CGPoint(x: c.x + r * 0.72, y: c.y - r * 0.72 - 8))] {
            ctx.draw(Text(t).font(UI.font(10)).foregroundColor(UI.muted), at: p)
        }
        let peak = max(a.left.map { abs($0) }.max() ?? 0, a.right.map { abs($0) }.max() ?? 0, 0.15)
        let gain = r * 0.92 / CGFloat(peak) * 0.7071
        for i in stride(from: 0, to: n, by: 2) {
            let l = CGFloat(a.left[i]), rr = CGFloat(a.right[i])
            // mid on the vertical axis, side on the horizontal axis
            let p = CGPoint(x: c.x + (rr - l) * gain, y: c.y - (l + rr) * gain)
            let age = Double(i) / Double(n)
            let dot: CGFloat = 1.6 + 1.2 * age
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)), with: .color(UI.accent.opacity(0.15 + 0.75 * age)))
        }
    }

    // 4. Radial: bars around a centre that pulses with the bass; rings leave the centre on bass onsets.
    static func radial(_ ctx: GraphicsContext, _ size: CGSize, _ a: Analyzer) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2), m = min(size.width, size.height) / 2
        let base = m * (0.30 + 0.05 * CGFloat(a.bass) + 0.04 * CGFloat(a.kick))
        for age in a.rings {
            let r = base + CGFloat(age) * (m - base)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(UI.accent.opacity(0.55 * Double(1 - age))), lineWidth: 2 + 3 * CGFloat(1 - age))
        }
        // Mirrored around the vertical axis: lowest frequencies at the bottom centre, highest at the top centre.
        let n = Analyzer.bandCount, reach = m * 0.62
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let isBass = a.bandFrequencies[i] < 150
            let len = 3 + reach * CGFloat(a.bands[i]) * (isBass ? 1.15 : 1)
            for side in [1.0, -1.0] {
                let angle = Double.pi / 2 - side * t * Double.pi
                let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
                var p = Path()
                p.move(to: CGPoint(x: c.x + dx * (base + 4), y: c.y + dy * (base + 4)))
                p.addLine(to: CGPoint(x: c.x + dx * (base + 4 + len), y: c.y + dy * (base + 4 + len)))
                ctx.stroke(p, with: .color(UI.accent.opacity(isBass ? 1 : 0.8)), style: StrokeStyle(lineWidth: max(1.8, m * 0.012), lineCap: .round))
            }
        }
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - base, y: c.y - base, width: base * 2, height: base * 2)), with: .color(UI.panel))
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - base, y: c.y - base, width: base * 2, height: base * 2)), with: .color(UI.accent.opacity(0.4 + 0.6 * Double(a.kick))), lineWidth: 2.5)
        ctx.draw(Text("BASS").font(UI.font(11)).foregroundColor(UI.muted), at: CGPoint(x: c.x, y: c.y - 9))
        ctx.draw(Text("\(Int((a.bass * 100).rounded()))").font(UI.font(max(18, base * 0.5), .heavy)).foregroundColor(UI.text), at: CGPoint(x: c.x, y: c.y + 8))
    }

    // 5. Waterfall: time across, frequency up, loudness as heat.
    static func waterfall(_ ctx: GraphicsContext, _ size: CGSize, _ a: Analyzer) {
        let palette = heatPalette()
        let cols = a.history.count, rows = Analyzer.historyBands
        let w = size.width / CGFloat(cols), h = (size.height - 18) / CGFloat(rows)
        // One path per colour step: ~50 fills a frame instead of thousands.
        var buckets = [Path](repeating: Path(), count: palette.count)
        for c in 0..<cols {
            let col = a.history[c]
            for r in 0..<rows {
                let value = col[r]
                if value < 0.04 { continue }
                let rect = CGRect(x: CGFloat(c) * w, y: (size.height - 18) - CGFloat(r + 1) * h, width: w + 0.5, height: h + 0.5)
                buckets[min(Int(value * Float(palette.count - 1)), palette.count - 1)].addRect(rect)
            }
        }
        for (i, path) in buckets.enumerated() where !path.isEmpty { ctx.fill(path, with: .color(palette[i])) }
        for f: Float in [50, 100, 250, 500, 1000, 2500, 5000, 10000] {
            let y = (size.height - 18) * (1 - position(of: f, a))
            ctx.draw(Text(freqLabel(f)).font(UI.font(10)).foregroundColor(UI.text.opacity(0.75)), at: CGPoint(x: 6, y: y), anchor: .leading)
        }
        ctx.draw(Text("◂ older").font(UI.font(10)).foregroundColor(UI.muted), at: CGPoint(x: 6, y: size.height - 8), anchor: .leading)
        ctx.draw(Text("now ▸").font(UI.font(10)).foregroundColor(UI.muted), at: CGPoint(x: size.width - 6, y: size.height - 8), anchor: .trailing)
    }
}

// MARK: - Views

struct VizCanvas: View {
    let mode: VizMode
    let analyzer: Analyzer
    /// Changes every frame: without it SwiftUI sees identical inputs (the analyzer is a class) and skips the redraw.
    var tick: Date = .distantPast
    var body: some View {
        Canvas { ctx, size in VizDraw.draw(mode, ctx, size, analyzer) }
    }
}

/// The Visualizer page: all five views live at once, each in its own card (one 30 fps timeline drives them all).
struct VisualizerPage: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        TimelineView(.animation) { timeline in
            let _ = m.refreshAnalyzer()   // analyse once per frame (up to the display rate)
            VStack(spacing: 14) {
                HStack(spacing: 14) { card(.spectrum, timeline.date); card(.impact, timeline.date); card(.scope, timeline.date) }
                HStack(spacing: 14) { card(.radial, timeline.date); card(.waterfall, timeline.date) }
            }
        }
    }

    private func card(_ mode: VizMode, _ tick: Date) -> some View {
        Panel(fill: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label2(text: mode.title)
                    Spacer()
                    Text(mode.caption).font(UI.font(10.5)).foregroundStyle(UI.muted).lineLimit(1)
                }
                VizCanvas(mode: mode, analyzer: m.analyzer, tick: tick)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(UI.bg.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
