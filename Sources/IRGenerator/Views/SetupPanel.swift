import IRCore
import SwiftUI

struct SetupPanel: View {
    @EnvironmentObject var model: CaptureModel

    private var busy: Bool { model.state != .idle && model.state != .levelCheck }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                interface.padding(12).gmCard()
                signal.padding(12).gmCard().disabled(busy)
                level.padding(12).gmCard()
                checklist.padding(12).gmCard()
                latency.padding(12).gmCard().disabled(busy)
            }
        }
    }

    // MARK: Interface

    private var interface: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Interface")
            FieldRow(label: "Device") {
                WellMenu(options: model.devices.map(\.uid) + (model.devices.isEmpty ? [""] : []),
                         selection: Binding(get: { model.settings.deviceUID ?? "" }, set: { model.settings.deviceUID = $0 })) { uid in
                    model.devices.first { $0.uid == uid }?.name ?? "No duplex device"
                }
            }
            .disabled(busy)
            FieldRow(label: "Send to") {
                LampSegmented(options: OutputRoute.allCases, selection: $model.settings.route) { $0.label }
            }
            .disabled(busy)
            FieldRow(label: "Channel") {
                LampSegmented(options: OutputSide.allCases, selection: $model.settings.side) { $0.label }
            }
            .disabled(busy)
            FieldRow(label: "Mic input") {
                LampSegmented(options: [0, 1], selection: $model.settings.inputChannel) { "IN \($0 + 1)" }
            }
            .disabled(busy)
            Text(routeHint).font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var routeHint: String {
        switch model.settings.route {
        case .ampOut: return "Amp Out (outputs 5/6) → power amp → cab → mic → input \(model.settings.inputChannel + 1). Use XLR, with phantom power for condensers."
        case .out12: return "Outputs 1/2 (line level). Use these for a loopback test: patch Out 1 into Input 2 set to LINE."
        case .out34: return "Outputs 3/4 (line level), e.g. into a line-level power amp input."
        }
    }

    // MARK: Signal

    private var signal: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Test signal")
            LampSegmented(options: MeasurementMethod.allCases, selection: $model.settings.measurement.method) { $0.label }
            if model.settings.measurement.method == .sweep {
                FieldRow(label: "Length") {
                    LampSegmented(options: [2.0, 4, 6, 10], selection: $model.settings.measurement.sweepSeconds) { "\(Int($0)) S" }
                }
                FieldRow(label: "Sweeps") {
                    LampSegmented(options: [1, 2, 4, 8], selection: $model.settings.measurement.averages) { "×\($0)" }
                }
            } else {
                FieldRow(label: "Periods") {
                    LampSegmented(options: [4, 8, 16, 32], selection: $model.settings.measurement.averages) { "×\($0)" }
                }
            }
            FieldRow(label: "Range") {
                WellMenu(options: [10.0, 15, 20, 30, 40], selection: $model.settings.measurement.f1) { "\(Int($0)) Hz" }
                Text("–").foregroundStyle(Theme.dim)
                WellMenu(options: [12000.0, 16000, 18000, 20000, 22000], selection: $model.settings.measurement.f2) { "\(Int($0 / 1000)) kHz" }
            }
            FieldRow(label: "Master IR") {
                LampSegmented(options: [0.5, 1, 2], selection: $model.settings.measurement.irSeconds) {
                    $0 < 1 ? "500 MS" : "\(Int($0)) S"
                }
            }
            LampCheck(text: "High-pass at 20 Hz", on: $model.settings.measurement.highPass,
                      detail: "Clears DC and sub-sonic rumble from the IR.")
            Text(signalHint).font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signalHint: String {
        let m = model.settings.measurement
        let total = Measurement.plan(m).duration
        switch m.method {
        case .sweep:
            return String(format: "Log sweep, the most accurate method. Power-amp distortion is pushed ahead of the impulse and trimmed off. About %.0f s.", total)
        case .pinkNoise, .whiteNoise:
            return String(format: "Periodic noise burst, averaged. Pink is gentler on tweeters. About %.0f s.", total)
        }
    }

    // MARK: Level

    private var level: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Output level")
            HStack(spacing: 8) {
                LevelSlider(value: $model.settings.levelDB, range: model.levelRange, step: 0.5,
                            tint: model.settings.levelDB > -12 ? Theme.danger : Theme.gold)
                LedReadout(text: String(format: "%5.1f dBFS", model.settings.levelDB),
                           color: model.settings.levelDB > -12 ? Theme.danger : Theme.amber)
            }
            HStack(spacing: 6) {
                Button {
                    model.settings.levelUnlocked.toggle()
                } label: {
                    Image(systemName: model.settings.levelUnlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(model.settings.levelUnlocked ? Theme.danger : Theme.gold)
                        .frame(width: 22, height: 18)
                        .background(LampFace(on: false, tint: model.settings.levelUnlocked ? Theme.danger : Theme.gold))
                }
                .buttonStyle(.plain)
                .help(model.settings.levelUnlocked ? "Lock the level at −12 dBFS max" : "Unlock levels above −12 dBFS")
                .accessibilityLabel(model.settings.levelUnlocked ? "Lock level ceiling" : "Unlock level ceiling")
                Text(model.settings.levelUnlocked ? "CEILING UNLOCKED · 0 dBFS" : "CEILING −12 dBFS")
                    .font(Theme.caption(9)).tracking(0.8).foregroundStyle(model.settings.levelUnlocked ? Theme.danger : Theme.dim)
            }
            FieldRow(label: "Check with") {
                LampSegmented(options: LevelSignal.allCases, selection: $model.settings.levelSignal) { $0.label }
            }
            Text("Run a level check, bring the power amp up to a moderate volume, then set the mic gain so the input peaks around −12 dBFS. Stop, then capture.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Safety

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Before capturing")
            ForEach(Array(CaptureModel.checklistItems.enumerated()), id: \.offset) { i, item in
                LampCheck(text: item.0, on: $model.checklist[i], detail: item.1)
            }
        }
    }

    // MARK: Latency

    private var latency: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Latency & alignment")
            HStack {
                if let ms = model.latencyMS, let l = model.settings.latency {
                    LedReadout(text: String(format: "%.2f ms · %d smp", ms, l), color: Theme.haze)
                } else {
                    LedReadout(text: "NOT CALIBRATED", color: Theme.steel)
                }
                Spacer()
                LatchButton(title: "CALIBRATE", on: false, tint: Theme.haze) { model.calibrateLatency() }
                    .frame(width: 92)
                    .help("Loopback: patch the selected output straight into the selected input, then calibrate")
            }
            LampCheck(text: "Keep mic distance delay", on: $model.settings.keepDelay,
                      detail: model.settings.latency == nil
                        ? "Needs a loopback calibration. Off: each IR starts at the direct sound."
                        : "IRs keep the mic's time of flight, for phase-aligning several mics.")
                .disabled(model.settings.latency == nil)
        }
    }
}
