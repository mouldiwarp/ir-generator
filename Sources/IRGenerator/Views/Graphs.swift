import IRCore
import SwiftUI

/// Shared plot geometry: the data area inside the axis labels.
struct PlotArea {
    static let left: CGFloat = 42, right: CGFloat = 12, top: CGFloat = 10, bottom: CGFloat = 24
    let rect: CGRect

    init(_ size: CGSize) {
        rect = CGRect(x: Self.left, y: Self.top, width: max(1, size.width - Self.left - Self.right),
                      height: max(1, size.height - Self.top - Self.bottom))
    }
}

private func gridLine(_ ctx: GraphicsContext, _ p: Path, major: Bool) {
    ctx.stroke(p, with: .color(major ? Theme.gold.opacity(0.22) : Color.white.opacity(0.05)), lineWidth: major ? 0.8 : 0.5)
}

private func axisLabel(_ ctx: GraphicsContext, _ s: String, at p: CGPoint, anchor: UnitPoint, color: Color = Theme.dim) {
    ctx.draw(Text(s).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(color), at: p, anchor: anchor)
}

private func formatHz(_ f: Double) -> String {
    f >= 1000 ? (f.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(f / 1000))k" : String(format: "%.1fk", f / 1000)) : "\(Int(f))"
}

// MARK: - Frequency response

struct FrequencyPlot: View {
    struct Series: Identifiable {
        let id: UUID
        let curve: Analysis.Curve
        let color: Color
        let name: String
    }

    let series: [Series]
    var fMin = 20.0, fMax = 20000.0
    var dbTop = 6.0, dbBottom = -48.0
    @State private var hover: CGPoint?

    /// Each curve is shifted so its maximum in 40 Hz–12 kHz sits at 0 dB.
    private func normalised(_ c: Analysis.Curve) -> [Double] {
        var m = -Double.infinity
        for (f, v) in zip(c.frequencies, c.dB) where f >= 40 && f <= 12000 { m = max(m, v) }
        return c.dB.map { $0 - (m.isFinite ? m : 0) }
    }

    var body: some View {
        let norm = series.map { normalised($0.curve) }
        Canvas { ctx, size in
            let a = PlotArea(size).rect
            let lf0 = log10(fMin), lf1 = log10(fMax)
            func x(_ f: Double) -> CGFloat { a.minX + CGFloat((log10(f) - lf0) / (lf1 - lf0)) * a.width }
            func y(_ d: Double) -> CGFloat { a.minY + CGFloat((dbTop - d) / (dbTop - dbBottom)) * a.height }

            ctx.fill(Path(a), with: .color(Theme.track.opacity(0.55)))
            // Grid
            for decade in [10.0, 100, 1000, 10000] {
                for k in 1...9 {
                    let f = decade * Double(k)
                    guard f >= fMin && f <= fMax else { continue }
                    var p = Path(); p.move(to: CGPoint(x: x(f), y: a.minY)); p.addLine(to: CGPoint(x: x(f), y: a.maxY))
                    gridLine(ctx, p, major: k == 1)
                }
            }
            for f in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] where f >= fMin && f <= fMax {
                axisLabel(ctx, formatHz(f), at: CGPoint(x: x(f), y: a.maxY + 5), anchor: .top)
            }
            var d = (dbBottom / 6).rounded(.up) * 6
            while d <= dbTop {
                var p = Path(); p.move(to: CGPoint(x: a.minX, y: y(d))); p.addLine(to: CGPoint(x: a.maxX, y: y(d)))
                gridLine(ctx, p, major: d == 0)
                if Int(d) % 12 == 0 { axisLabel(ctx, "\(Int(d))", at: CGPoint(x: a.minX - 5, y: y(d)), anchor: .trailing) }
                d += 6
            }
            axisLabel(ctx, "dB", at: CGPoint(x: 4, y: a.minY), anchor: .topLeading, color: Theme.gold.opacity(0.8))
            axisLabel(ctx, "Hz", at: CGPoint(x: a.minX - 14, y: a.maxY + 5), anchor: .topTrailing, color: Theme.gold.opacity(0.8))

            // Curves: compared first, selected (index 0) on top with a glow.
            ctx.clip(to: Path(a))
            for (i, s) in series.enumerated().reversed() {
                var p = Path()
                for (k, f) in s.curve.frequencies.enumerated() where f >= fMin && f <= fMax {
                    let pt = CGPoint(x: x(f), y: y(norm[i][k]))
                    if p.isEmpty { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                if i == 0 {
                    ctx.drawLayer { g in
                        g.addFilter(.blur(radius: 3))
                        g.stroke(p, with: .color(s.color.opacity(0.6)), lineWidth: 3)
                    }
                }
                ctx.stroke(p, with: .color(s.color.opacity(i == 0 ? 1 : 0.8)), lineWidth: i == 0 ? 1.8 : 1.2)
            }

            // Hover crosshair and readouts
            if let h = hover, a.contains(h) {
                let f = pow(10, lf0 + Double((h.x - a.minX) / a.width) * (lf1 - lf0))
                var p = Path(); p.move(to: CGPoint(x: h.x, y: a.minY)); p.addLine(to: CGPoint(x: h.x, y: a.maxY))
                ctx.stroke(p, with: .color(Theme.offwhite.opacity(0.35)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                var lines = [String(format: "%@ Hz", f >= 1000 ? String(format: "%.2fk", f / 1000) : String(format: "%.0f", f))]
                for (i, s) in series.enumerated() {
                    let fr = s.curve.frequencies
                    guard let k = fr.firstIndex(where: { $0 >= f }) else { continue }
                    let v = norm[i][k]
                    let pt = CGPoint(x: x(fr[k]), y: y(v))
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)), with: .color(s.color))
                    lines.append(abs(v) < 0.05 ? "0.0 dB" : String(format: "%+.1f dB", v))
                }
                let tx = h.x + (h.x > a.midX ? -8 : 8)
                for (j, l) in lines.enumerated() {
                    let c = j == 0 ? Theme.offwhite : series[j - 1].color
                    ctx.draw(Text(l).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(c),
                             at: CGPoint(x: tx, y: a.minY + 8 + CGFloat(j) * 14), anchor: h.x > a.midX ? .topTrailing : .topLeading)
                }
            }
        }
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover = p } else { hover = nil }
        }
        .accessibilityLabel("Frequency response")
    }
}

// MARK: - Impulse

struct ImpulsePlot: View {
    struct Series: Identifiable {
        let id: UUID
        let samples: [Double]
        let sampleRate: Double
        let color: Color
    }

    let series: [Series]
    let mode: ImpulseMode
    /// Visible span in ms (0 = whole IR).
    let span: Double

    var body: some View {
        Canvas { ctx, size in
            let a = PlotArea(size).rect
            let longest = series.map { Double($0.samples.count) / $0.sampleRate * 1000 }.max() ?? 100
            let ms = span > 0 ? span : longest
            func x(_ t: Double) -> CGFloat { a.minX + CGFloat(t / ms) * a.width }
            let etc = mode == .etc
            let dbFloor = -90.0
            func y(_ v: Double) -> CGFloat {
                if etc { return a.minY + CGFloat(min(1, max(0, -v / -dbFloor))) * a.height }
                return a.midY - CGFloat(v) * a.height * 0.47
            }

            ctx.fill(Path(a), with: .color(Theme.track.opacity(0.55)))
            // Time grid
            let stepMS = niceStep(ms / 8)
            var t = 0.0
            while t <= ms + 1e-9 {
                var p = Path(); p.move(to: CGPoint(x: x(t), y: a.minY)); p.addLine(to: CGPoint(x: x(t), y: a.maxY))
                gridLine(ctx, p, major: false)
                axisLabel(ctx, stepMS < 1 ? String(format: "%.1f", t) : "\(Int(t.rounded()))", at: CGPoint(x: x(t), y: a.maxY + 5), anchor: .top)
                t += stepMS
            }
            axisLabel(ctx, "ms", at: CGPoint(x: a.minX - 10, y: a.maxY + 5), anchor: .topTrailing, color: Theme.gold.opacity(0.8))
            if etc {
                for d in stride(from: 0.0, through: dbFloor, by: -10) {
                    var p = Path(); p.move(to: CGPoint(x: a.minX, y: y(d))); p.addLine(to: CGPoint(x: a.maxX, y: y(d)))
                    gridLine(ctx, p, major: d == 0)
                    if Int(d) % 20 == 0 { axisLabel(ctx, "\(Int(d))", at: CGPoint(x: a.minX - 5, y: y(d)), anchor: .trailing) }
                }
                axisLabel(ctx, "dB", at: CGPoint(x: 4, y: a.minY), anchor: .topLeading, color: Theme.gold.opacity(0.8))
            } else {
                for v in [-1.0, -0.5, 0, 0.5, 1] {
                    var p = Path(); p.move(to: CGPoint(x: a.minX, y: y(v))); p.addLine(to: CGPoint(x: a.maxX, y: y(v)))
                    gridLine(ctx, p, major: v == 0)
                    axisLabel(ctx, v == 0 ? "0" : String(format: "%+.1f", v), at: CGPoint(x: a.minX - 5, y: y(v)), anchor: .trailing)
                }
            }
            // Export-length markers (48 kHz sample counts)
            for (n, label) in [(1024, "1024"), (2048, "2048"), (4096, "4096"), (8192, "8192")] {
                let tm = Double(n) / 48
                guard tm < ms else { continue }
                var p = Path(); p.move(to: CGPoint(x: x(tm), y: a.minY)); p.addLine(to: CGPoint(x: x(tm), y: a.maxY))
                ctx.stroke(p, with: .color(Theme.amber.opacity(0.45)), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                axisLabel(ctx, label, at: CGPoint(x: x(tm) + 3, y: a.minY + 3), anchor: .topLeading, color: Theme.amber.opacity(0.8))
            }

            ctx.clip(to: Path(a))
            let cols = Int(a.width)
            for (i, s) in series.enumerated().reversed() {
                let pk = Processing.peak(s.samples)
                guard pk > 0 else { continue }
                let total = min(s.samples.count, Int(ms / 1000 * s.sampleRate))
                guard total > 1 else { continue }
                var p = Path()
                if total <= cols * 2 && !etc {
                    for k in 0..<total {
                        let pt = CGPoint(x: x(Double(k) / s.sampleRate * 1000), y: y(s.samples[k] / pk))
                        if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                } else {
                    // Per-column min/max (waveform) or max |h| (energy).
                    let per = Double(total) / Double(cols)
                    for c in 0..<cols {
                        let s0 = Int(Double(c) * per), s1 = max(s0 + 1, min(total, Int(Double(c + 1) * per)))
                        var lo = Double.infinity, hi = -Double.infinity
                        for k in s0..<s1 { lo = min(lo, s.samples[k]); hi = max(hi, s.samples[k]) }
                        let px = a.minX + CGFloat(c)
                        if etc {
                            let v = Analysis.dB(max(abs(lo), abs(hi)) / pk)
                            let pt = CGPoint(x: px, y: y(max(dbFloor, v)))
                            if c == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        } else {
                            p.move(to: CGPoint(x: px, y: y(hi / pk))); p.addLine(to: CGPoint(x: px, y: y(lo / pk) + 0.5))
                        }
                    }
                }
                ctx.stroke(p, with: .color(s.color.opacity(i == 0 ? 1 : 0.7)), lineWidth: i == 0 ? 1.4 : 1)
            }
        }
        .accessibilityLabel("Impulse response")
    }
}

func niceStep(_ raw: Double) -> Double {
    guard raw > 0 else { return 1 }
    let p = pow(10, floor(log10(raw)))
    for m in [1.0, 2, 5, 10] where raw <= m * p { return m * p }
    return 10 * p
}

// MARK: - Recording

struct RecordingPlot: View {
    let samples: [Double]
    let sampleRate: Double
    var color: Color = Theme.gold

    var body: some View {
        Canvas { ctx, size in
            let a = PlotArea(size).rect
            let secs = Double(samples.count) / sampleRate
            func x(_ t: Double) -> CGFloat { a.minX + CGFloat(t / max(secs, 1e-9)) * a.width }
            func y(_ v: Double) -> CGFloat { a.midY - CGFloat(v) * a.height * 0.48 }
            ctx.fill(Path(a), with: .color(Theme.track.opacity(0.55)))
            let step = niceStep(secs / 10)
            var t = 0.0
            while t <= secs {
                var p = Path(); p.move(to: CGPoint(x: x(t), y: a.minY)); p.addLine(to: CGPoint(x: x(t), y: a.maxY))
                gridLine(ctx, p, major: false)
                axisLabel(ctx, step < 1 ? String(format: "%.1f", t) : "\(Int(t))", at: CGPoint(x: x(t), y: a.maxY + 5), anchor: .top)
                t += step
            }
            axisLabel(ctx, "s", at: CGPoint(x: a.minX - 10, y: a.maxY + 5), anchor: .topTrailing, color: Theme.gold.opacity(0.8))
            for (v, l) in [(1.0, "0 dB"), (0.5, "−6"), (0.0, ""), (-0.5, "−6"), (-1.0, "0 dB")] {
                var p = Path(); p.move(to: CGPoint(x: a.minX, y: y(v))); p.addLine(to: CGPoint(x: a.maxX, y: y(v)))
                if abs(v) == 1 { ctx.stroke(p, with: .color(Theme.danger.opacity(0.45)), lineWidth: 0.8) } else { gridLine(ctx, p, major: v == 0) }
                if !l.isEmpty { axisLabel(ctx, l, at: CGPoint(x: a.minX - 5, y: y(v)), anchor: .trailing) }
            }
            let env = Analysis.envelope(samples, buckets: Int(a.width))
            var p = Path()
            for (c, e) in env.enumerated() {
                let px = a.minX + CGFloat(c)
                p.move(to: CGPoint(x: px, y: y(e.max))); p.addLine(to: CGPoint(x: px, y: y(e.min) + 0.5))
            }
            ctx.stroke(p, with: .color(color), lineWidth: 1)
        }
        .accessibilityLabel("Recorded response")
    }
}

// MARK: - Spectrogram

struct SpectrogramPlot: View {
    let data: Analysis.Spectrogram

    var body: some View {
        let image = Self.render(data)
        Canvas { ctx, size in
            let a = PlotArea(size).rect
            if let image { ctx.draw(Image(decorative: image, scale: 1), in: a) }
            ctx.stroke(Path(a), with: .color(Theme.gold.opacity(0.25)), lineWidth: 0.8)
            let lf0 = log10(data.fMin), lf1 = log10(data.fMax)
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] where f > data.fMin && f <= data.fMax {
                let yy = a.maxY - CGFloat((log10(f) - lf0) / (lf1 - lf0)) * a.height
                var p = Path(); p.move(to: CGPoint(x: a.minX, y: yy)); p.addLine(to: CGPoint(x: a.minX + 5, y: yy))
                ctx.stroke(p, with: .color(Theme.offwhite.opacity(0.5)), lineWidth: 0.8)
                axisLabel(ctx, formatHz(f), at: CGPoint(x: a.minX - 5, y: yy), anchor: .trailing)
            }
            let step = niceStep(data.duration / 10)
            var t = 0.0
            while t <= data.duration {
                let xx = a.minX + CGFloat(t / data.duration) * a.width
                axisLabel(ctx, step < 1 ? String(format: "%.1f", t) : "\(Int(t))", at: CGPoint(x: xx, y: a.maxY + 5), anchor: .top)
                t += step
            }
            axisLabel(ctx, "s", at: CGPoint(x: a.minX - 10, y: a.maxY + 5), anchor: .topTrailing, color: Theme.gold.opacity(0.8))
            axisLabel(ctx, "Hz", at: CGPoint(x: 4, y: a.minY), anchor: .topLeading, color: Theme.gold.opacity(0.8))
        }
        .accessibilityLabel("Spectrogram of the recording")
    }

    /// obsidian → smoky blue → gold → white, over −100…0 dB.
    static func render(_ d: Analysis.Spectrogram) -> CGImage? {
        let stops: [(Float, (Float, Float, Float))] = [
            (0, (0.03, 0.03, 0.04)), (0.35, (0.10, 0.16, 0.24)), (0.6, (0.53, 0.64, 0.74)),
            (0.82, (0.77, 0.63, 0.35)), (1, (1, 0.97, 0.88)),
        ]
        func color(_ t: Float) -> (UInt8, UInt8, UInt8) {
            for i in 1..<stops.count where t <= stops[i].0 {
                let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
                let u = (t - t0) / (t1 - t0)
                return (UInt8((c0.0 + (c1.0 - c0.0) * u) * 255), UInt8((c0.1 + (c1.1 - c0.1) * u) * 255),
                        UInt8((c0.2 + (c1.2 - c0.2) * u) * 255))
            }
            return (255, 247, 224)
        }
        var px = [UInt8](repeating: 255, count: d.rows * d.columns * 4)
        for r in 0..<d.rows {
            let row = d.rows - 1 - r       // top row = highest frequency
            for c in 0..<d.columns {
                let v = d.values[r * d.columns + c]
                let (R, G, B) = color(max(0, min(1, (v + 100) / 100)))
                let o = (row * d.columns + c) * 4
                px[o] = R; px[o + 1] = G; px[o + 2] = B
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: d.columns, height: d.rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: d.columns * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
