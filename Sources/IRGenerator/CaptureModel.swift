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

/// Settings for the Align & Blend and Mic Swap tools (stored separately from AppSettings).
struct ToolSettings: Codable, Equatable {
    var micSourceID = "sm57"
    /// nil = remove the mic (speaker only).
    var micTargetID: String? = "r121"
    var mic = MicSwap.Options()
    /// Reference IR's weight in a two-IR blend, 0…1.
    var blendMix = 0.5
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
    /// Input peak readout: holds each new peak for `holdTime`, then follows the meter down.
    @Published var inHoldDB: Double = -100
    private var holdSince = Date.distantPast
    static let holdTime: TimeInterval = 1.5

    func updateHold(_ peakDB: Double, meterDB: Double) {
        let now = Date()
        if peakDB >= inHoldDB {
            inHoldDB = peakDB
            holdSince = now
        } else if now.timeIntervalSince(holdSince) > Self.holdTime {
            inHoldDB = max(peakDB, meterDB)
        }
    }
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
    @Published var showAlign = false
    @Published var showChecklist = false
    @Published var showMicSwap = false
    @Published var tools: ToolSettings { didSet { saveTools() } }
    @Published private(set) var micCurves: [MicCurve] = MicLibrary.builtIn
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
        tools = (UserDefaults.standard.data(forKey: "tools")).flatMap { try? JSONDecoder().decode(ToolSettings.self, from: $0) }
            ?? ToolSettings()
        if !demo { micCurves = MicLibrary.builtIn + Library.loadMicCurves() }
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
        // Sweeps average 1–8 runs; noise needs more periods for the same signal-to-noise ratio.
        if settings.measurement.method != old.measurement.method {
            let noise = settings.measurement.method != .sweep
            if noise && settings.measurement.averages < 4 { settings.measurement.averages = 8 }
            if !noise && settings.measurement.averages > 8 { settings.measurement.averages = 1 }
        }
        if settings.levelDB != old.levelDB, engine.isRunning, state == .levelCheck { engine.setGain(gain) }
        if settings.levelSignal != old.levelSignal || settings.route != old.route || settings.side != old.side
            || settings.inputChannel != old.inputChannel, state == .levelCheck {
            stopRun(); startLevelCheck()
        }
        if settings.graph != old.graph { /* view-only */ }
        guard !isDemo, let d = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(d, forKey: "settings")
    }

    private func saveTools() {
        guard !isDemo, let d = try? JSONEncoder().encode(tools) else { return }
        UserDefaults.standard.set(d, forKey: "tools")
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
            showChecklist = true          // the sheet's Capture button comes back here once it's ticked
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
        meters.reset()
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
        meters.updateHold(Analysis.dB(Double(s.inPeak)), meterDB: Analysis.dB(Double(meters.inPeak)))
        if let plan = runPlan, case .capturing = state {
            meters.progress = min(1, Double(s.recorded) / Double(max(1, plan.recordFrames)))
            meters.remaining = Double(max(0, plan.recordFrames - s.recorded)) / plan.settings.sampleRate
        }
        guard s.done, case .capturing(let calibration) = state, let plan = runPlan else { return }
        timer?.invalidate(); timer = nil
        let rec = engine.stop()
        meters.reset()      // the capture's input peak is kept with the capture (PEAK IN)
        if s.aborted || rec == nil {
            state = .idle
            post(.info, "Capture stopped.")
            return
        }
        state = .processing
        let latency = latency(for: plan.settings.sampleRate)
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
        if settings.keepDelay && latency(for: fs) != nil && !r.keptDelay {
            post(.warning, "This run's round trip was shorter than the calibrated latency (USB timing varies by about 1 ms between runs), so this IR starts at the direct sound instead of keeping the mic delay. Use Align & Blend to line up mics.")
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

    private func latency(for rate: Double) -> Int? { settings.latencyRate == rate ? settings.latency : nil }

    // MARK: - Library

    /// Rebuilds a capture's IR from its saved recording, trimmed at the direct sound.
    func reprocess(_ meta: CaptureMeta) {
        guard let s = meta.settings, let rec = audio(meta.id)?.recording else { return }
        let plan = Measurement.plan(s)
        guard plan.recordFrames == rec.count else {
            post(.error, "“\(meta.name)”: the recording doesn't match its settings, so it can't be reprocessed.")
            return
        }
        let r = Measurement.process(recording: rec, plan: plan)
        var m = meta
        m.delaySamples = r.delaySamples
        m.peakToNoiseDB = r.peakToNoiseDB
        m.inputPeakDB = r.inputPeakDB
        m.clipped = r.clipped
        let audio = CaptureAudio(ir: r.ir, recording: rec)
        audioCache[m.id] = audio
        curveCache = curveCache.filter { !$0.key.hasPrefix(m.id.uuidString) }
        if !isDemo {
            do { try Library.save(m, audio: CaptureAudio(ir: r.ir, recording: nil)) }
            catch { post(.error, "Couldn't save “\(m.name)”: \(error.localizedDescription)") }
        }
        update(m)
        post(.info, "Reprocessed “\(m.name)” from its recording.")
    }

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

    // MARK: - Derived IRs (align, blend, mic swap)

    /// Adds a processed IR to the library as a new capture.
    @discardableResult
    func addDerived(from source: CaptureMeta, name: String, note: String, ir: [Double], sampleRate: Double? = nil,
                    select: Bool = true) -> CaptureMeta {
        var meta = CaptureMeta(name: name, sampleRate: sampleRate ?? source.sampleRate)
        meta.settings = source.settings
        meta.route = source.route
        meta.levelDB = source.levelDB
        meta.derivedFrom = note
        meta.notes = source.notes
        let audio = CaptureAudio(ir: ir, recording: nil)
        audioCache[meta.id] = audio
        if !isDemo {
            do { try Library.save(meta, audio: audio) } catch { post(.error, "Couldn't save “\(name)”: \(error.localizedDescription)") }
        }
        captures.insert(meta, at: 0)
        if select { selectedID = meta.id }
        return meta
    }

    /// The IR resampled to `rate` if needed (for comparing captures made at different rates).
    func ir(_ meta: CaptureMeta, at rate: Double) -> [Double]? {
        guard let h = audio(meta.id)?.ir else { return nil }
        return meta.sampleRate == rate ? h : Processing.resample(h, from: meta.sampleRate, to: rate)
    }

    func mic(_ id: String?) -> MicCurve? { id.flatMap { i in micCurves.first { $0.id == i } } }

    func importMicCurve() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .text, .data]
        panel.message = "Choose a mic response file: lines of “frequency dB” (REW .txt, .frd or .csv)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
              let curve = MicCurve.parse(text, name: url.deletingPathExtension().lastPathComponent) else {
            post(.error, "\(url.lastPathComponent) has no readable “frequency dB” lines.")
            return
        }
        if !isDemo { try? Library.saveMicCurve(curve) }
        micCurves.append(curve)
        post(.info, "Imported mic curve “\(curve.name)” (\(curve.points.count) points). Set its polar pattern in Mic Swap.")
    }

    func updateMicCurve(_ c: MicCurve) {
        guard let i = micCurves.firstIndex(where: { $0.id == c.id }), !c.builtIn else { return }
        micCurves[i] = c
        if !isDemo { try? Library.saveMicCurve(c) }
    }

    func deleteMicCurve(_ id: String) {
        guard let c = mic(id), !c.builtIn else { return }
        micCurves.removeAll { $0.id == id }
        if !isDemo { Library.deleteMicCurve(id) }
        if tools.micSourceID == id { tools.micSourceID = "sm57" }
        if tools.micTargetID == id { tools.micTargetID = nil }
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
        var h = a.ir
        let cut = settings.export.highCut
        if cut > 0 { h = Processing.lowPass(h, cutoff: cut, sampleRate: meta.sampleRate) }
        let n = settings.graph.viewLength
        guard n > 0 else { return h }
        let len = Int((Double(n) * meta.sampleRate / 48000).rounded())
        return Processing.truncate(h, length: len, fadeFraction: settings.export.fadeFraction)
    }

    func curve(_ meta: CaptureMeta) -> Analysis.Curve? {
        let g = settings.graph
        let key = "\(meta.id)-\(g.smoothing)-\(g.viewLength)-\(settings.export.fadeFraction)-\(settings.export.highCut)"
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
