import IRCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: CaptureModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            ForEach(model.notices) { n in NoticeBanner(notice: n) }
            if !model.microphoneAuthorized && !model.isDemo {
                NoticeBanner(notice: Notice(kind: .warning, text: "IR Generator needs microphone access to record the AXE I/O's inputs."),
                             action: ("Allow…", { model.requestMicrophone() }))
            }
            HStack(alignment: .top, spacing: 10) {
                SetupPanel().frame(width: 304)
                GraphPanel()
                LibraryPanel().frame(width: 272)
            }
            .padding(10)
            TransportBar(meters: model.meters)
        }
        .background(Backdrop())
        .background(WindowTint())
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1260, minHeight: 800)
        .sheet(isPresented: $model.showExport) {
            if let m = model.selected { ExportSheet(meta: m).environmentObject(model) }
        }
        .sheet(isPresented: $model.showAlign) {
            AlignSheet(members: model.plotted.map(\.meta)).environmentObject(model)
        }
        .sheet(isPresented: $model.showMicSwap) {
            if let m = model.selected { MicSwapSheet(meta: m).environmentObject(model) }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var model: CaptureModel

    var body: some View {
        HStack(spacing: 10) {
            ImpulseGlyph().frame(width: 22, height: 16)
            Text("IR GENERATOR").font(Theme.headingBold(15)).tracking(2.5).foregroundStyle(Theme.offwhite)
            Text("Cab impulse capture").font(Theme.heading(11.5)).foregroundStyle(Theme.dim)
            Spacer()
            if let d = model.device {
                LedDot(on: true, color: d.isAxeIO ? Theme.ok : Theme.warn)
                Text(d.name.uppercased()).font(Theme.caption(10.5)).tracking(1).foregroundStyle(Theme.text.opacity(0.85))
                LedReadout(text: String(format: "%.1f kHz", d.nominalRate / 1000))
            } else {
                LedDot(on: true, color: Theme.danger)
                Text("NO INTERFACE").font(Theme.caption(10.5)).tracking(1).foregroundStyle(Theme.danger)
            }
            if model.isDemo { LedReadout(text: "DEMO", color: Theme.haze) }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Theme.obsidian.opacity(0.88))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gold.opacity(0.4)).frame(height: 1) }
    }
}

/// The app's mark: a gold impulse spike decaying into a sweep.
struct ImpulseGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            let w = size.width, h = size.height
            p.move(to: CGPoint(x: 0, y: h * 0.75))
            p.addLine(to: CGPoint(x: w * 0.18, y: h * 0.75))
            p.addLine(to: CGPoint(x: w * 0.24, y: 0))
            p.addLine(to: CGPoint(x: w * 0.31, y: h))
            for i in 0..<14 {
                let t = Double(i) / 13
                let x = w * (0.31 + 0.69 * t)
                let y = h * 0.75 + (i.isMultiple(of: 2) ? -1 : 1) * h * 0.3 * (1 - t)
                p.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(p, with: .color(Theme.gold), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .shadow(color: Theme.gold.opacity(0.7), radius: 3)
        .accessibilityHidden(true)
    }
}

struct NoticeBanner: View {
    @EnvironmentObject var model: CaptureModel
    let notice: Notice
    var action: (String, () -> Void)? = nil

    var color: Color {
        switch notice.kind {
        case .info: return Theme.haze
        case .warning: return Theme.warn
        case .error: return Theme.danger
        }
    }

    var body: some View {
        HStack {
            Image(systemName: notice.kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
            Text(notice.text).lineLimit(3).textSelection(.enabled)
            Spacer()
            if let action { Button(action.0, action: action.1) }
            Button { model.dismiss(notice.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color)
    }
}

// MARK: - Transport

struct TransportBar: View {
    @EnvironmentObject var model: CaptureModel
    @ObservedObject var meters: MeterState

    private var running: Bool {
        if case .capturing = model.state { return true }
        return false
    }

    private var statusText: String {
        switch model.state {
        case .idle: return model.checklistComplete ? "READY" : "COMPLETE THE SAFETY CHECKLIST"
        case .levelCheck: return "LEVEL CHECK · SET THE POWER AMP AND MIC GAIN"
        case .capturing(let cal):
            return String(format: "%@ · %.0f%% · %.0f s", cal ? "CALIBRATING" : "CAPTURING", meters.progress * 100, meters.remaining.rounded(.up))
        case .processing: return "PROCESSING"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText).font(Theme.caption(11)).tracking(1.2)
                    .foregroundStyle(model.state == .idle ? Theme.dim : Theme.amber)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.track)
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.gold)
                            .frame(width: g.size.width * (running ? meters.progress : model.state == .processing ? 1 : 0))
                            .shadow(color: Theme.gold.opacity(0.7), radius: 3)
                    }
                }
                .frame(minWidth: 120, maxWidth: 260, minHeight: 3, maxHeight: 3)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            readout("OUT", meters.outPeak)
            readout("IN", meters.inPeak, hold: meters.inHoldDB)
            if let l = model.latencyMS {
                VStack(spacing: 2) {
                    Text("LATENCY").font(Theme.caption(8.5)).tracking(1).foregroundStyle(Theme.dim)
                    LedReadout(text: String(format: "%.2f ms", l), color: Theme.haze)
                }
            }
            Divider().frame(height: 26)
            LatchButton(title: model.state == .levelCheck ? "STOP CHECK" : "LEVEL CHECK", on: model.state == .levelCheck,
                        tint: Theme.haze, height: 30) { model.toggleLevelCheck() }
                .frame(width: 112)
                .disabled(running || model.state == .processing)
                .help("Loop a test signal so you can set the power amp and mic gain (⌘L)")
            if running {
                BigLampButton(title: "STOP", systemImage: "stop.fill", tint: Theme.danger) { model.stop() }
                    .help("Fade out and abandon the capture (Esc)")
            } else {
                BigLampButton(title: "CAPTURE", systemImage: "waveform.path", enabled: model.state != .processing) { model.capture() }
                    .help("Play the test signal and capture an IR (⌘R)")
            }
            BigLampButton(title: "EXPORT", systemImage: "square.and.arrow.down", lit: false, enabled: model.selected != nil) {
                model.showExport = true
            }
            .help("Export WAV files for TONEX, AmpliTube and Fractal (⌘E)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.obsidian.opacity(0.9))
        .overlay(alignment: .top) { Rectangle().fill(Theme.gold.opacity(0.4)).frame(height: 1) }
    }

    private func readout(_ label: String, _ v: Float, hold: Double? = nil) -> some View {
        let value = hold ?? Analysis.dB(Double(v))
        let clip = value > -0.2
        return HStack(spacing: 6) {
            Text(label).font(Theme.caption(9)).tracking(1).foregroundStyle(Theme.dim)
            HMeter(level: v).frame(minWidth: 70, maxWidth: 120)
            LedReadout(text: value <= -99 ? "   −∞" : String(format: "%5.1f", value), color: clip ? Theme.danger : Theme.amber)
                .frame(width: 58, alignment: .trailing)
            LedDot(on: clip, color: Theme.danger)
        }
        .help(hold != nil ? "Input peak: each new peak is held for 1.5 s, then the readout follows the level down" : "Output peak")
    }
}
