import IRCore
import SwiftUI

struct GraphPanel: View {
    @EnvironmentObject var model: CaptureModel

    private var g: Binding<GraphSettings> { $model.settings.graph }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LampSegmented(options: GraphTab.allCases, selection: g.tab) { $0.label }
                    .frame(maxWidth: 440)
                Spacer(minLength: 0)
            }
            if model.settings.graph.tab == .frequency || model.settings.graph.tab == .impulse {
                HStack(spacing: 10) { controls; Spacer(minLength: 0) }
            }
            ZStack {
                plot
                if model.plotted.isEmpty { emptyState }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(6)
            .gmWell(radius: 6)
            legend
        }
        .padding(12)
        .gmCard()
    }

    @ViewBuilder private var controls: some View {
        switch model.settings.graph.tab {
        case .frequency:
            Text("SMOOTH").font(Theme.caption(9)).tracking(1).foregroundStyle(Theme.dim)
            LampSegmented(options: [0.0, 12, 6, 3], selection: g.smoothing) { $0 == 0 ? "OFF" : "1/\(Int($0)) OCT" }
                .frame(width: 250)
            lengthMenu
        case .impulse:
            LampSegmented(options: ImpulseMode.allCases, selection: g.impulseMode) { $0.label }.frame(width: 180)
            LampSegmented(options: [5.0, 20, 50, 200, 0], selection: g.impulseSpan) { $0 == 0 ? "ALL" : "\(Int($0)) MS" }
                .frame(width: 220)
            lengthMenu
        case .recording, .spectrogram:
            EmptyView()
        }
    }

    private var lengthMenu: some View {
        HStack(spacing: 6) {
            Text("HIGH CUT").font(Theme.caption(9)).tracking(1).foregroundStyle(Theme.dim)
            WellMenu(options: [0.0, 16000, 12000, 10000, 8000, 6000], selection: Binding(
                get: { model.settings.export.highCut }, set: { model.settings.export.highCutHz = $0 > 0 ? $0 : nil })) {
                $0 == 0 ? "Off" : "\(Int($0 / 1000)) kHz"
            }
            .frame(width: 84)
            .help("24 dB/octave high cut, used for export and previewed here. 10–12 kHz removes noise above a cab's roll-off without changing its tone.")
            Text("LENGTH").font(Theme.caption(9)).tracking(1).foregroundStyle(Theme.dim)
            WellMenu(options: [0, 8192, 4096, 2048, 1024], selection: g.viewLength) { $0 == 0 ? "Master" : "\($0) smp" }
                .frame(width: 100)
                .help("Preview the IR cut to an export length")
        }
    }

    @ViewBuilder private var plot: some View {
        let plotted = model.plotted
        switch model.settings.graph.tab {
        case .frequency:
            FrequencyPlot(series: plotted.compactMap { p in
                model.curve(p.meta).map { FrequencyPlot.Series(id: p.meta.id, curve: $0, color: p.color, name: p.meta.name) }
            })
        case .impulse:
            ImpulsePlot(series: plotted.compactMap { p in
                model.previewIR(p.meta).map { ImpulsePlot.Series(id: p.meta.id, samples: $0, sampleRate: p.meta.sampleRate, color: p.color) }
            }, mode: model.settings.graph.impulseMode, span: model.settings.graph.impulseSpan)
        case .recording:
            if let m = model.selected, let r = model.audio(m.id)?.recording {
                RecordingPlot(samples: r, sampleRate: m.sampleRate)
            } else if model.selected != nil {
                placeholder("No recording for this IR (imported file).")
            }
        case .spectrogram:
            if let m = model.selected, let s = model.spectrogram(m) {
                SpectrogramPlot(data: s)
            } else if model.selected != nil {
                placeholder("No recording for this IR (imported file).")
            }
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).font(Theme.heading(12)).foregroundStyle(Theme.dim)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ImpulseGlyph().frame(width: 64, height: 44).opacity(0.8)
            Text("NO IMPULSE RESPONSES YET").font(Theme.caption(13)).tracking(1.6).foregroundStyle(Theme.gold)
            Text("Patch Amp Out → power amp → cab, mic the speaker into Input 1,\nrun a level check, then press Capture. Or import a WAV IR to view it.")
                .multilineTextAlignment(.center).font(Theme.heading(12)).foregroundStyle(Theme.dim)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(model.plotted, id: \.meta.id) { p in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(p.color).frame(width: 14, height: 3)
                        .shadow(color: p.color.opacity(0.8), radius: 2)
                    Text(p.meta.name).font(Theme.heading(11)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }
            }
            Spacer()
            if let m = model.selected { metrics(m) }
        }
        .frame(height: 22)
    }

    @ViewBuilder private func metrics(_ m: CaptureMeta) -> some View {
        if let pnr = m.peakToNoiseDB {
            metric("PNR", String(format: "%.0f dB", pnr), color: pnr < 45 ? Theme.warn : Theme.amber)
        }
        if let d = m.delaySamples {
            metric("DELAY", String(format: "%.2f ms", Double(d) / m.sampleRate * 1000))
        }
        if let p = m.inputPeakDB {
            metric("PEAK IN", String(format: "%.1f dB", p), color: m.clipped ? Theme.danger : Theme.amber)
        }
        if let a = model.audio(m.id) {
            metric("LENGTH", a.ir.count >= Int(m.sampleRate / 10)
                   ? String(format: "%.2f s", Double(a.ir.count) / m.sampleRate) : "\(a.ir.count) smp")
        }
    }

    private func metric(_ label: String, _ value: String, color: Color = Theme.amber) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.caption(8.5)).tracking(1).foregroundStyle(Theme.dim)
            LedReadout(text: value, color: color, size: 10)
        }
    }
}
