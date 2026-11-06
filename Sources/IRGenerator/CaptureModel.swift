import AppKit
import AVFoundation
import IRCore
import SwiftUI

/// Where the test signal goes. AXE I/O output channels: 1/2 = Out 1-2, 3/4 = Out 3-4, 5/6 = Amp Out.
enum OutputRoute: String, Codable, CaseIterable {
    case ampOut, out12, out34

    var label: String { ["AMP OUT", "OUT 1/2", "OUT 3/4"][Self.allCases.firstIndex(of: self)!] }
    var channels: [Int] {
        switch self {
        case .ampOut: return [4, 5]
        case .out12: return [0, 1]
        case .out34: return [2, 3]
        }
    }
}

enum OutputSide: String, Codable, CaseIterable {
    case left, right, both
    var label: String { rawValue.uppercased() }
}

enum LevelSignal: String, Codable, CaseIterable {
    case pink, tone
    var label: String { self == .pink ? "PINK NOISE" : "1 kHz TONE" }
}

struct AppSettings: Codable, Equatable {
    var deviceUID: String?
    var measurement = MeasurementSettings()
    var route: OutputRoute = .ampOut
    var side: OutputSide = .both
    var inputChannel = 0
    var levelDB: Double = -30
    var levelUnlocked = false
    var levelSignal: LevelSignal = .pink
    /// Round-trip latency from a loopback calibration, in samples at `latencyRate`.
    var latency: Int?
    var latencyRate: Double?
    var keepDelay = false
    var export = ExportOptions()
    var exportPresetIDs: Set<String> = ["fractal-2048", "fractal-8192", "ik-4096"]
    var exportFolder: String?
    var graph = GraphSettings()

    static let lockedCeiling = -12.0
}

enum GraphTab: String, Codable, CaseIterable {
    case frequency, impulse, recording, spectrogram
    var label: String { rawValue.uppercased() }
}

enum ImpulseMode: String, Codable, CaseIterable {
    case linear, etc
    var label: String { self == .linear ? "WAVEFORM" : "ENERGY (dB)" }
}

struct GraphSettings: Codable, Equatable {
    var tab: GraphTab = .frequency
    /// Fractional-octave smoothing; 0 = none.
    var smoothing: Double = 6
    /// Preview the response at an export length (samples at 48 kHz); 0 = full master.
    var viewLength = 0
    var impulseMode: ImpulseMode = .linear
    /// Milliseconds shown in the impulse view.
    var impulseSpan: Double = 50
}

enum RunState: Equatable {
    case idle, levelCheck, capturing(calibration: Bool), processing
}

/// Meters and progress, updated 30 times a second during a run.
@MainActor
final class MeterState: ObservableObject {
    @Published var progress: Double = 0
    @Published var inPeak: Float = 0
    @Published var outPeak: Float = 0
    @Published var inHoldDB: Double = -100
    /// Seconds left in the current capture.
    @Published var remaining: Double = 0

    func reset() { progress = 0; inPeak = 0; outPeak = 0; inHoldDB = -100; remaining = 0 }
}

struct Notice: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    let id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
final class CaptureModel: ObservableObject {
    @Published var settings: AppSettings { didSet { settingsChanged(oldValue) } }
    @Published private(set) var devices: [AudioDevice] = []
    @Published var captures: [CaptureMeta] = []
    @Published var selectedID: UUID?
    @Published var compareIDs: Set<UUID> = []
    @Published private(set) var state: RunState = .idle
    /// Fast-changing values live apart, so meter updates don't redraw the graphs.
    let meters = MeterState()
    @Published var notices: [Notice] = []
    /// Safety checklist; reset every launch.
    @Published var checklist: [Bool] = [false, false, false, false]
    @Published var showExport = false
    @Published private(set) var microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    let isDemo: Bool
    private let engine = CaptureEngine()
    private var timer: Timer?
    private var runPlan: MeasurementPlan?
    private var runStarted = Date()
    private var audioCache: [UUID: CaptureAudio] = [:]
    private var curveCache: [String: Analysis.Curve] = [:]
    private var spectroCache: [UUID: Analysis.Spectrogram] = [:]

    static let checklistItems: [(String, String)] = [
        ("To Amp Out is OFF", "Otherwise Input 1 is routed to Amp Out and the mic feeds back through the cab."),
        ("Direct monitoring is down", "Turn the AXE I/O's monitor/direct mix away from the mic input."),
        ("Power amp volume is low", "Start quiet and raise it after a level check."),
        ("Hearing and tweeters protected", "Sweeps carry full-range energy. Wear ear protection near the cab."),
    ]

    init(demo: Bool = false) {
        isDemo = demo
        settings = Self.loadSettings()
        refreshDevices()
        if demo {
            loadDemo()
        } else {
            captures = Library.loadAll()
            selectedID = captures.first?.id
            AudioDevices.observeDeviceList { [weak self] in self?.refreshDevices() }
        }
    }

    // MARK: - Settings

    private static func loadSettings() -> AppSettings {
        guard let d = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }

    private func settingsChanged(_ old: AppSettings) {
        if !settings.levelUnlocked && settings.levelDB > AppSettings.lockedCeiling { settings.levelDB = AppSettings.lockedCeiling }
        if settings.levelDB != old.levelDB, engine.isRunning, state == .levelCheck { engine.setGain(gain) }
        if settings.levelSignal != old.levelSignal || settings.route != old.route || settings.side != old.side
            || settings.inputChannel != old.inputChannel, state == .levelCheck {
            stopRun(); startLevelCheck()
        }
        if settings.graph != old.graph { /* view-only */ }
        guard !isDemo, let d = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(d, forKey: "settings")
    }

    var gain: Float { Float(pow(10, settings.levelDB / 20)) }
    var levelRange: ClosedRange<Double> { -60...(settings.levelUnlocked ? 0 : AppSettings.lockedCeiling) }
    var checklistComplete: Bool { checklist.allSatisfy { $0 } }

    // MARK: - Devices

    func refreshDevices() {
        devices = AudioDevices.duplex()
        if settings.deviceUID == nil || !devices.contains(where: { $0.uid == settings.deviceUID }) {
            if let axe = devices.first(where: \.isAxeIO) { settings.deviceUID = axe.uid }
        }
        if state != .idle, let uid = settings.deviceUID, !devices.contains(where: { $0.uid == uid }) {
            stopRun()
            post(.error, "The audio interface was disconnected.")
        }
    }

    var device: AudioDevice? { devices.first { $0.uid == settings.deviceUID } }

    var outputChannels: [Int] {
        let ch = settings.route.channels
        switch settings.side {
        case .left: return [ch[0]]
        case .right: return [ch[1]]
        case .both: return ch
        }
    }

    var latencyMS: Double? {
        guard let l = settings.latency, let r = settings.latencyRate else { return nil }
        return Double(l) / r * 1000
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { self.microphoneAuthorized = ok }
        }
    }

    // MARK: - Runs

    private func prepare() -> (AudioDevice, Double)? {
        guard let dev = device else { post(.error, "Choose an audio interface first (the AXE I/O)."); return nil }
        guard microphoneAuthorized else {
            post(.warning, "Allow microphone access so the app can record the AXE I/O's inputs.")
            requestMicrophone()
            return nil
        }
        let rate = AudioDevices.setRate(dev.id, 48000)
        return (dev, rate > 0 ? rate : 48000)
    }

    func toggleLevelCheck() { state == .levelCheck ? stopRun() : startLevelCheck() }

    func startLevelCheck() {
        guard state == .idle, let (dev, fs) = prepare() else { return }
        let signal: [Double]
        switch settings.levelSignal {
        case .pink: signal = Signals.periodicNoise(length: 1 << 16, sampleRate: fs, f1: 40, f2: 16000, pink: true)
        case .tone: signal = Signals.tone(frequency: 1000, seconds: 1, sampleRate: fs)
        }
        do {
            try engine.start(device: dev, signal: signal, loop: true, outChannels: outputChannels,
                             inChannel: settings.inputChannel, recordFrames: nil, gain: gain)
            state = .levelCheck
            meters.reset()
            startTimer()
        } catch { post(.error, error.localizedDescription) }
    }

    func capture() { startCapture(calibration: false) }
    func calibrateLatency() { startCapture(calibration: true) }

    private func startCapture(calibration: Bool) {
        if state == .levelCheck { stopRun() }
        guard state == .idle else { return }
        guard calibration || checklistComplete else {
            post(.warning, "Tick the safety checklist before the first capture.")
            return
        }
        guard let (dev, fs) = prepare() else { return }
        var m = settings.measurement
        m.sampleRate = fs
        if calibration { m.method = .sweep; m.averages = 1; m.sweepSeconds = 2; m.tail = 0.5; m.highPass = false }
        let plan = Measurement.plan(m)
        do {
            try engine.start(device: dev, signal: plan.playback, loop: false, outChannels: outputChannels,
                             inChannel: settings.inputChannel, recordFrames: plan.recordFrames, gain: gain)
        } catch { post(.error, error.localizedDescription); return }
        runPlan = plan
        runStarted = Date()
        meters.reset()
        state = .capturing(calibration: calibration)
        startTimer()
    }

    /// Stop button / Esc: fades out and abandons the run.
    func stop() {
        switch state {
        case .levelCheck: stopRun()
        case .capturing: engine.requestStop()
        default: break
        }
    }

    private func stopRun() {
        timer?.invalidate(); timer = nil
        engine.stop()
        state = .idle
        meters.inPeak = 0; meters.outPeak = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let s = engine.status()
        // Meter ballistics: instant attack, ~300 ms release.
        meters.inPeak = max(s.inPeak, meters.inPeak * 0.8)
        meters.outPeak = max(s.outPeak, meters.outPeak * 0.8)
        meters.inHoldDB = max(meters.inHoldDB, Analysis.dB(Double(s.inPeak)))
        if let plan = runPlan, case .capturing = state {
            meters.progress = min(1, Double(s.recorded) / Double(max(1, plan.recordFrames)))
            meters.remaining = Double(max(0, plan.recordFrames - s.recorded)) / plan.settings.sampleRate
        }
        guard s.done, case .capturing(let calibration) = state, let plan = runPlan else { return }
        timer?.invalidate(); timer = nil
        let rec = engine.stop()
        meters.inPeak = 0; meters.outPeak = 0
        if s.aborted || rec == nil {
            state = .idle
            post(.info, "Capture stopped.")
            return
        }
        state = .processing
        let latency = settings.latencyRate == plan.settings.sampleRate ? settings.latency : nil
        let keep = settings.keepDelay
        let recording = rec!
        Task.detached(priority: .userInitiated) {
            let result = Measurement.process(recording: recording, plan: plan, latency: latency, keepDelay: keep && latency != nil)
            await MainActor.run { self.finish(result, recording: recording, plan: plan, calibration: calibration) }
        }
    }

    private func finish(_ r: MeasurementResult, recording: [Double], plan: MeasurementPlan, calibration: Bool) {
        state = .idle
        let fs = plan.settings.sampleRate
        if r.clipped { post(.warning, "The input clipped. Turn down the mic gain on the AXE I/O (or the output level) and capture again.") }
        else if r.inputPeakDB < -45 { post(.warning, String(format: "The input was very quiet (peak %.0f dBFS). Check the input, the phantom power and the mic gain.", r.inputPeakDB)) }
        if calibration {
            guard r.peakToNoiseDB > 30 else {
                post(.error, "No clear loopback signal. Patch the selected output straight into the selected input and try again.")
                return
            }
            settings.latency = r.delaySamples
            settings.latencyRate = fs
            post(.info, String(format: "Round-trip latency: %d samples (%.2f ms).", r.delaySamples, Double(r.delaySamples) / fs * 1000))
            return
        }
        if r.peakToNoiseDB < 45 && !r.clipped {
            post(.warning, String(format: "Peak-to-noise is only %.0f dB. Raise the level or mic gain, add averages, or quieten the room.", r.peakToNoiseDB))
        }
        let n = captures.filter { !$0.isImported }.count + 1
        var meta = CaptureMeta(name: "Capture \(n)", sampleRate: fs)
        meta.settings = plan.settings
        meta.route = "\(settings.route.label) → IN \(settings.inputChannel + 1)"
        meta.levelDB = settings.levelDB
        meta.delaySamples = r.delaySamples
        meta.peakToNoiseDB = r.peakToNoiseDB
        meta.inputPeakDB = r.inputPeakDB
        meta.clipped = r.clipped
        meta.hasRecording = true
        let audio = CaptureAudio(ir: r.ir, recording: recording)
        audioCache[meta.id] = audio
        if !isDemo {
            do { try Library.save(meta, audio: audio) } catch { post(.error, "Couldn't save the capture: \(error.localizedDescription)") }
        }
        captures.insert(meta, at: 0)
        selectedID = meta.id
    }

    // MARK: - Library

    var selected: CaptureMeta? { captures.first { $0.id == selectedID } }

    func audio(_ id: UUID) -> CaptureAudio? {
        if let a = audioCache[id] { return a }
        guard let meta = captures.first(where: { $0.id == id }), let a = Library.loadAudio(meta) else { return nil }
        audioCache[id] = a
        return a
    }

    func update(_ meta: CaptureMeta) {
        guard let i = captures.firstIndex(where: { $0.id == meta.id }) else { return }
        captures[i] = meta
        if !isDemo { try? Library.saveMeta(meta) }
    }

    func delete(_ id: UUID) {
        captures.removeAll { $0.id == id }
        compareIDs.remove(id)
        audioCache[id] = nil
        spectroCache[id] = nil
        if !isDemo { Library.delete(id) }
        if selectedID == id { selectedID = captures.first?.id }
    }

    func toggleCompare(_ id: UUID) {
        if compareIDs.contains(id) { compareIDs.remove(id) } else { compareIDs.insert(id) }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = true
        panel.message = "Choose impulse-response WAV files to view and compare"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importFile(url) }
    }

    func importFile(_ url: URL) {
        do {
            let d = try WavFile.read(url)
            var meta = CaptureMeta(name: url.deletingPathExtension().lastPathComponent, sampleRate: d.sampleRate)
            meta.importedFrom = url.path
            meta.notes = "\(d.samples.count) samples · \(Int(d.sampleRate)) Hz · \(d.isFloat ? "float" : "\(d.bitsPerSample)-bit")"
                + (d.channels > 1 ? " · first of \(d.channels) channels" : "")
            let audio = CaptureAudio(ir: d.samples, recording: nil)
            audioCache[meta.id] = audio
            if !isDemo { try Library.save(meta, audio: audio) }
            captures.insert(meta, at: 0)
            selectedID = meta.id
        } catch {
            post(.error, "\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Export

    func filename(base: String, preset: ExportPreset) -> String {
        let tag = preset.platform == ExportPreset.fractal ? "Fractal" : "TONEX"
        return "\(ExportRenderer.sanitize(base))_\(tag)_\(preset.fileSuffix).wav"
    }

    /// Writes one file per preset into `folder`. Returns the files written.
    func export(_ meta: CaptureMeta, base: String, presets: [ExportPreset], to folder: URL) throws -> [URL] {
        guard let a = audio(meta.id) else { throw WavError.truncated }
        var out: [URL] = []
        for p in presets {
            let h = ExportRenderer.render(a.ir, masterRate: meta.sampleRate, preset: p, options: settings.export)
            let url = folder.appendingPathComponent(filename(base: base, preset: p))
            try WavFile.write(h, sampleRate: p.sampleRate, format: p.format, to: url)
            out.append(url)
        }
        return out
    }

    /// The full-length master, 32-bit float, at the capture rate (normalised to −0.1 dBFS peak).
    func saveMaster(_ meta: CaptureMeta) {
        guard let a = audio(meta.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(ExportRenderer.sanitize(meta.name))_master_\(Int(meta.sampleRate / 1000))k.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WavFile.write(Processing.normalizedPeak(a.ir), sampleRate: Int(meta.sampleRate), format: .float32, to: url)
            post(.info, "Saved \(url.lastPathComponent).")
        } catch { post(.error, error.localizedDescription) }
    }

    func saveRecording(_ meta: CaptureMeta) {
        guard let r = audio(meta.id)?.recording else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(ExportRenderer.sanitize(meta.name))_recording.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try WavFile.write(r, sampleRate: Int(meta.sampleRate), format: .float32, to: url) }
        catch { post(.error, error.localizedDescription) }
    }

    // MARK: - Plot data

    static let palette: [Color] = [Theme.gold, Theme.haze, Theme.ok, Color(hex: 0xD98BD0), Theme.danger, Theme.offwhite, Theme.amber]

    /// Selected capture first, then compared ones, each with a stable colour.
    var plotted: [(meta: CaptureMeta, color: Color)] {
        var ids: [UUID] = []
        if let s = selectedID { ids.append(s) }
        ids += captures.map(\.id).filter { compareIDs.contains($0) && $0 != selectedID }
        return ids.enumerated().compactMap { i, id in
            captures.first { $0.id == id }.map { ($0, Self.palette[i % Self.palette.count]) }
        }
    }

    /// The IR as previewed in the graphs: optionally cut to an export length (with the export fade).
    func previewIR(_ meta: CaptureMeta) -> [Double]? {
        guard let a = audio(meta.id) else { return nil }
        let n = settings.graph.viewLength
        guard n > 0 else { return a.ir }
        let len = Int((Double(n) * meta.sampleRate / 48000).rounded())
        return Processing.truncate(a.ir, length: len, fadeFraction: settings.export.fadeFraction)
    }

    func curve(_ meta: CaptureMeta) -> Analysis.Curve? {
        let g = settings.graph
        let key = "\(meta.id)-\(g.smoothing)-\(g.viewLength)-\(settings.export.fadeFraction)"
        if let c = curveCache[key] { return c }
        guard let h = previewIR(meta) else { return nil }
        let c = Analysis.response(h, sampleRate: meta.sampleRate, smoothing: g.smoothing > 0 ? g.smoothing : nil, points: 600)
        curveCache[key] = c
        return c
    }

    func spectrogram(_ meta: CaptureMeta) -> Analysis.Spectrogram? {
        if let s = spectroCache[meta.id] { return s }
        guard let r = audio(meta.id)?.recording else { return nil }
        let s = Analysis.spectrogram(r, sampleRate: meta.sampleRate, columns: 600, rows: 220)
        spectroCache[meta.id] = s
        return s
    }

    // MARK: - Notices

    func post(_ kind: Notice.Kind, _ text: String) {
        notices.removeAll { $0.text == text }
        notices.append(Notice(kind: kind, text: text))
        if notices.count > 3 { notices.removeFirst() }
        if kind == .info {
            let id = notices.last!.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.notices.removeAll { $0.id == id } }
        }
    }

    func dismiss(_ id: UUID) { notices.removeAll { $0.id == id } }

    func shutdown() { stopRun() }

    // MARK: - Demo (screenshots and trying the UI without hardware)

    private func loadDemo() {
        let fs = 48000.0
        let names = [("V30 · SM57 cap edge", "1 in. from grille, on the dust-cap edge"),
                     ("V30 · SM57 cone", "Halfway out the cone"),
                     ("Greenback · R121", "Ribbon, 2 in. back, centre")]
        for (i, (name, notes)) in names.enumerated() {
            var m = MeasurementSettings()
            m.averages = 2
            let plan = Measurement.plan(m)
            let cab = Simulator.cabIR(sampleRate: fs, length: 24000, delay: 60 + 25 * i, variant: i)
            let rec = Simulator.record(plan, through: cab, latency: 389, level: 0.25, noiseDB: -82, drive: 1.2, seed: UInt64(i + 1))
            let r = Measurement.process(recording: rec, plan: plan)
            var meta = CaptureMeta(name: name, sampleRate: fs)
            meta.notes = notes
            meta.date = Date().addingTimeInterval(Double(-600 * i))
            meta.settings = m
            meta.route = "AMP OUT → IN 1"
            meta.levelDB = -24
            meta.delaySamples = r.delaySamples
            meta.peakToNoiseDB = r.peakToNoiseDB
            meta.inputPeakDB = r.inputPeakDB
            meta.hasRecording = true
            audioCache[meta.id] = CaptureAudio(ir: r.ir, recording: rec)
            captures.append(meta)
        }
        selectedID = captures.first?.id
        compareIDs = Set(captures.dropFirst().map(\.id))
        settings.latency = 389
        settings.latencyRate = fs
        checklist = [true, true, true, true]
    }

    /// For --snapshot: switches tabs from outside the views.
    func setTab(_ t: GraphTab) { settings.graph.tab = t }
}
