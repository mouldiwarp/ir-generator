import IRCore
import SwiftUI

/// Align & Blend: phase-aligns the compared IRs to a reference by band-limited cross-correlation, previews the
/// blend before and after, and saves aligned IRs or the blend as new library entries.
struct AlignSheet: View {
    @EnvironmentObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    let members: [CaptureMeta]

    @State private var referenceID: UUID
    @State private var flips: [UUID: Bool] = [:]
    @State private var analysis: Analysis?
    @State private var saved: String?

    /// Everything computed for the current reference.
    struct Analysis {
        var rate: Double
        var reference: CaptureMeta
        var others: [CaptureMeta]
        var irs: [[Double]]                  // reference first, as captured
        var results: [IRCore.Alignment.Result]
    }

    init(members: [CaptureMeta]) {
        self.members = members
        _referenceID = State(initialValue: members.first?.id ?? UUID())
    }

    private var colors: [Color] { CaptureModel.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ImpulseGlyph().frame(width: 22, height: 16)
                Text("ALIGN & BLEND").font(Theme.headingBold(14)).tracking(2)
                Spacer()
                Text("Phase-align IRs so they blend without comb filtering").font(Theme.heading(11.5)).foregroundStyle(Theme.dim)
            }
            FieldRow(label: "Reference") {
                WellMenu(options: members.map(\.id), selection: $referenceID) { id in members.first { $0.id == id }?.name ?? "" }
            }
            if let a = analysis {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(a.others.enumerated()), id: \.element.id) { i, m in row(m, a.results[i], a.rate) }
                }
                .padding(10)
                .gmWell(radius: 6)

                if a.others.count == 1 {
                    HStack(spacing: 8) {
                        FieldRow(label: "Mix") {
                            Text(a.reference.name).font(Theme.heading(10.5)).foregroundStyle(Theme.dim).lineLimit(1).frame(width: 110, alignment: .trailing)
                            LevelSlider(value: $model.tools.blendMix, range: 0...1, step: 0.05)
                            Text(a.others[0].name).font(Theme.heading(10.5)).foregroundStyle(Theme.dim).lineLimit(1).frame(width: 110, alignment: .leading)
                            LedReadout(text: String(format: "%3.0f/%-3.0f", model.tools.blendMix * 100, (1 - model.tools.blendMix) * 100))
                        }
                    }
                }

                FrequencyPlot(series: plotSeries(a))
                    .frame(height: 300)
                    .padding(6)
                    .gmWell(radius: 6)
                HStack(spacing: 14) {
                    legend(Theme.danger.opacity(0.85), "Blend as captured", dashed: true)
                    legend(Theme.gold, "Blend aligned")
                    Spacer()
                    Text("Correlation band 80 Hz – 4 kHz · search ±5 ms").font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
            } else {
                Text("Analysing…").font(Theme.heading(12)).foregroundStyle(Theme.dim).frame(height: 360)
            }
            if let saved { HStack { LedDot(on: true); Text(saved).font(Theme.heading(12)).foregroundStyle(Theme.ok) } }
            HStack {
                Text("Alignment works from the waveforms only, so it finds the best-summing position rather than the true mic distance.")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                Spacer()
                LatchButton(title: "CLOSE", on: false, height: 28) { dismiss() }
                    .frame(width: 90).keyboardShortcut(.cancelAction)
                LatchButton(title: "SAVE ALIGNED IRs", on: false, height: 28) { saveAligned() }
                    .frame(width: 150).disabled(analysis == nil)
                BigLampButton(title: "SAVE BLEND", systemImage: "square.stack.3d.down.forward", enabled: analysis != nil) { saveBlend() }
            }
        }
        .padding(18)
        .frame(width: 820)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onAppear { analyze() }
        .onChange(of: referenceID) { _, _ in analyze() }
    }

    // MARK: - Rows

    private func row(_ m: CaptureMeta, _ r: IRCore.Alignment.Result, _ rate: Double) -> some View {
        let flip = flips[m.id] ?? r.inverted
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(color(for: m)).frame(width: 3, height: 20)
            Text(m.name).font(Theme.heading(12)).lineLimit(1).frame(width: 220, alignment: .leading)
            Text("SHIFT").font(Theme.caption(8.5)).tracking(1).foregroundStyle(Theme.dim)
            LedReadout(text: String(format: "%+6.2f smp · %+.3f ms", r.shift, r.shift / rate * 1000))
            Text("MATCH").font(Theme.caption(8.5)).tracking(1).foregroundStyle(Theme.dim)
            LedReadout(text: String(format: "%3.0f%%", r.correlation * 100), color: r.correlation < 0.5 ? Theme.warn : Theme.amber)
            Spacer()
            LatchButton(title: flip ? "Ø INVERTED" : "Ø NORMAL", on: flip, tint: Theme.danger) { flips[m.id] = !flip }
                .frame(width: 104)
                .help(r.inverted ? "Detected as polarity-inverted against the reference" : "Polarity matches the reference")
        }
    }

    private func color(for m: CaptureMeta) -> Color {
        guard let i = members.firstIndex(where: { $0.id == m.id }) else { return Theme.dim }
        return colors[i % colors.count]
    }

    private func legend(_ c: Color, _ s: String, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(c).frame(width: 16, height: 3).opacity(dashed ? 0.8 : 1)
            Text(s).font(Theme.heading(11)).foregroundStyle(Theme.text.opacity(0.9))
        }
    }

    // MARK: - Processing

    private func analyze() {
        guard let ref = members.first(where: { $0.id == referenceID }) else { return }
        let others = members.filter { $0.id != referenceID }
        let rate = ref.sampleRate
        guard let refIR = model.ir(ref, at: rate) else { return }
        let irs = [refIR] + others.compactMap { model.ir($0, at: rate) }
        guard irs.count == others.count + 1 else { return }
        // The first ~170 ms carries everything that matters for blending; the noisy tail only dilutes it.
        let window = Int(0.17 * rate)
        let results = irs.dropFirst().map {
            IRCore.Alignment.analyze(reference: Array(refIR.prefix(window)), Array($0.prefix(window)), sampleRate: rate)
        }
        flips = [:]
        saved = nil
        analysis = Analysis(rate: rate, reference: ref, others: others, irs: irs, results: results)
    }

    private func aligned(_ a: Analysis) -> [[Double]] {
        IRCore.Alignment.apply(reference: a.irs[0], others: Array(a.irs.dropFirst()), results: a.results,
                        flipPolarity: a.others.enumerated().map { i, m in flips[m.id] ?? a.results[i].inverted })
    }

    private func weights(_ a: Analysis) -> [Double] {
        a.others.count == 1 ? [model.tools.blendMix, 1 - model.tools.blendMix] : [Double](repeating: 1, count: a.irs.count)
    }

    private func plotSeries(_ a: Analysis) -> [FrequencyPlot.Series] {
        let w = weights(a)
        let before = IRCore.Alignment.blend(a.irs, weights: w)
        let after = IRCore.Alignment.blend(aligned(a), weights: w)
        // Same normalisation for both blends, so the cancellation shows up as a level loss.
        let cb = IRCore.Analysis.response(before, sampleRate: a.rate, smoothing: 12, points: 500)
        let ca = IRCore.Analysis.response(after, sampleRate: a.rate, smoothing: 12, points: 500)
        let ref = zip(ca.frequencies, ca.dB).filter { $0.0 >= 40 && $0.0 <= 12000 }.map(\.1).max() ?? 0
        func shifted(_ c: IRCore.Analysis.Curve) -> IRCore.Analysis.Curve {
            IRCore.Analysis.Curve(frequencies: c.frequencies, dB: c.dB.map { $0 - ref })
        }
        return [
            FrequencyPlot.Series(id: UUID(), curve: shifted(ca), color: Theme.gold, name: "Aligned", normalize: false),
            FrequencyPlot.Series(id: UUID(), curve: shifted(cb), color: Theme.danger.opacity(0.85), name: "As captured",
                                 normalize: false, dashed: true),
        ]
    }

    private func saveAligned() {
        guard let a = analysis else { return }
        let out = aligned(a)
        let all = [a.reference] + a.others
        var n = 0
        for (i, m) in all.enumerated() {
            // The reference only changes if every other IR had to be delayed past it.
            if i == 0 && out[0] == a.irs[0] { continue }
            let r = i == 0 ? nil : a.results[i - 1]
            let note = i == 0 ? "Aligned set reference" :
                String(format: "Aligned to “%@”: %+.2f samples%@", a.reference.name, r!.shift,
                       (flips[m.id] ?? r!.inverted) ? ", polarity inverted" : "")
            model.addDerived(from: m, name: "\(m.name) · aligned", note: note, ir: out[i], sampleRate: a.rate, select: false)
            n += 1
        }
        saved = "Saved \(n) aligned IR\(n == 1 ? "" : "s") to the library."
    }

    private func saveBlend() {
        guard let a = analysis else { return }
        let w = weights(a)
        let blend = Processing.normalizedPeak(IRCore.Alignment.blend(aligned(a), weights: w))
        let all = [a.reference] + a.others
        let total = w.reduce(0, +)
        let parts = zip(all, w).map { String(format: "%@ %.0f%%", $0.0.name, $0.1 / total * 100) }
        let name = "Blend · " + all.map(\.name).joined(separator: " + ")
        model.addDerived(from: a.reference, name: name, note: "Aligned blend: " + parts.joined(separator: ", "),
                         ir: blend, sampleRate: a.rate, select: false)
        saved = "Saved “\(name)” to the library."
    }
}
