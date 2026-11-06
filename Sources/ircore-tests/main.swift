import Foundation
import IRCore

// Offline tests for IRCore. Run: swift run -c release ircore-tests

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)  \(detail())")
    if !ok { failures += 1 }
}

let fs = 48000.0

/// Error energy of `a` against reference `b`, in dB relative to the energy of `b`.
func errorDB(_ a: [Double], _ b: [Double]) -> Double {
    let n = min(a.count, b.count)
    var e = 0.0, r = 0.0
    for i in 0..<n { e += (a[i] - b[i]) * (a[i] - b[i]); r += b[i] * b[i] }
    return 10 * log10(max(e, 1e-300) / r)
}

/// Largest in-band magnitude difference (dB) between two IRs, 1/12-octave, 50 Hz…15 kHz.
func maxResponseDiff(_ a: [Double], _ b: [Double], rate: Double = fs, lo: Double = 50, hi: Double = 15000) -> Double {
    let ca = Analysis.response(a, sampleRate: rate, smoothing: 12, fMin: lo, fMax: hi)
    let cb = Analysis.response(b, sampleRate: rate, smoothing: 12, fMin: lo, fMax: hi)
    // Compare shapes (ignore any overall gain difference).
    let off = zip(ca.dB, cb.dB).map { $0 - $1 }
    let mean = off.reduce(0, +) / Double(off.count)
    return off.map { abs($0 - mean) }.max() ?? 0
}

// Diagnostics: ircore-tests --reprocess <capture folder> rebuilds a saved capture's IR and reports it.
if let i = CommandLine.arguments.firstIndex(of: "--reprocess"), i + 1 < CommandLine.arguments.count {
    struct Meta: Decodable { var settings: MeasurementSettings }
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let meta = try! JSONDecoder().decode(Meta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
    let rec = try! WavFile.read(dir.appendingPathComponent("recording.wav")).samples
    let plan = Measurement.plan(meta.settings)
    print("recording \(rec.count) / plan \(plan.recordFrames)")
    let r = Measurement.process(recording: rec, plan: plan)
    let c = Analysis.response(r.ir, sampleRate: meta.settings.sampleRate, smoothing: 6, points: 9, fMin: 50, fMax: 12800)
    print(String(format: "delay %d, PNR %.1f dB, peak index %d", r.delaySamples, r.peakToNoiseDB, Processing.peakIndex(r.ir)))
    print("response (1/6 oct):", zip(c.frequencies, c.dB).map { String(format: "%.0f Hz %.2f", $0, $1 - c.dB[4]) }.joined(separator: " · "))
    exit(0)
}

print("FFT")
do {
    let n = 1 << 21
    let fft = FFT(size: n)
    var x = [Double](repeating: 0, count: n); x[5] = 1
    let X = fft.forward(real: x)
    let back = fft.inverseReal(X.re, X.im)
    check("2^21-point round trip", abs(back[5] - 1) < 1e-9 && abs(back[6]) < 1e-9)
}

let cab = Simulator.cabIR(sampleRate: fs, length: 8192)
let delay = 300

print("Sine sweep")
do {
    var s = MeasurementSettings()
    s.f1 = 10; s.f2 = 23500; s.sweepSeconds = 2; s.highPass = false
    let plan = Measurement.plan(s)
    let truth = Processing.slice(cab, start: 0, length: 8192)
    let rec = Simulator.record(plan, through: [Double](repeating: 0, count: delay) + cab, latency: 0, level: 1, noiseDB: -140)
    let r = Measurement.process(recording: rec, plan: plan)
    check("onset found at the acoustic delay", abs(r.delaySamples - delay) <= 2, "got \(r.delaySamples)")
    // r.ir starts `preroll` samples before the onset; realign to the truth.
    let pre = delay - r.delaySamples + Measurement.preroll(fs)
    let rec8k = Processing.slice(r.ir, start: pre, length: 6000)
    let e = errorDB(rec8k, Array(truth[0..<6000]))
    check("time-domain error < −40 dB", e < -40, String(format: "%.1f dB", e))
    let d = maxResponseDiff(rec8k, Array(truth[0..<6000]), hi: 10000)
    check("response within ±0.2 dB, 50 Hz–10 kHz", d < 0.2, String(format: "%.3f dB", d))
    check("peak-to-noise high with a clean signal", r.peakToNoiseDB > 80, String(format: "%.1f dB", r.peakToNoiseDB))
}

do {
    // Realistic: 20 Hz–20 kHz, interface latency, noise, distortion, averaging.
    var s = MeasurementSettings()
    s.sweepSeconds = 4
    let plan1 = Measurement.plan(s)
    s.averages = 4
    let plan4 = Measurement.plan(s)
    let path = [Double](repeating: 0, count: 140) + cab
    let r1 = Measurement.process(recording: Simulator.record(plan1, through: path, latency: 412, level: 0.1, noiseDB: -70, drive: 2), plan: plan1)
    let n1 = Measurement.process(recording: Simulator.record(plan1, through: path, latency: 412, level: 0.1, noiseDB: -70), plan: plan1)
    let n4 = Measurement.process(recording: Simulator.record(plan4, through: path, latency: 412, level: 0.1, noiseDB: -70), plan: plan4)
    check("delay = latency + acoustic", abs(r1.delaySamples - 552) <= 2, "got \(r1.delaySamples)")
    let d = maxResponseDiff(Processing.slice(r1.ir, start: 0, length: 6000), Array(cab[0..<6000]), lo: 60, hi: 12000)
    check("distorted, noisy sweep still within ±0.5 dB (60 Hz–12 kHz)", d < 0.5, String(format: "%.3f dB", d))
    check("4 averages improve peak-to-noise by ≥ 5 dB", n4.peakToNoiseDB - n1.peakToNoiseDB > 5,
          String(format: "%.1f → %.1f dB", n1.peakToNoiseDB, n4.peakToNoiseDB))
    check("not clipped", !r1.clipped)
    // Distortion products land before the impulse; the trimmed IR shouldn't have energy before the onset.
    let preEnergy = r1.ir[0..<8].reduce(0) { $0 + $1 * $1 }, total = r1.ir.reduce(0) { $0 + $1 * $1 }
    check("harmonic distortion removed from the IR", 10 * log10(preEnergy / total) < -40)
}

print("Keep delay")
do {
    var s = MeasurementSettings(); s.sweepSeconds = 2; s.highPass = false
    let plan = Measurement.plan(s)
    let rec = Simulator.record(plan, through: [Double](repeating: 0, count: 40) + cab, latency: 1275, noiseDB: -100)
    let ok = Measurement.process(recording: rec, plan: plan, latency: 1258, keepDelay: true)
    check("keeps the acoustic delay after the calibrated latency", ok.keptDelay && Processing.peakIndex(ok.ir) > 40 + 17)
    // Calibration said 1299, but this run's round trip was shorter: never cut off the direct sound.
    let late = Measurement.process(recording: rec, plan: plan, latency: 1299 + 40, keepDelay: true)
    check("falls back to the direct sound when the latency overshoots", !late.keptDelay
          && Processing.peakIndex(late.ir) >= Measurement.preroll(fs) && Processing.peakIndex(late.ir) < 40)
}

print("Periodic noise")
for pink in [true, false] {
    var s = MeasurementSettings()
    s.method = pink ? .pinkNoise : .whiteNoise
    s.averages = 4; s.f1 = 10; s.f2 = 23500; s.highPass = false
    let plan = Measurement.plan(s)
    let rec = Simulator.record(plan, through: [Double](repeating: 0, count: delay) + cab, latency: 200, level: 1, noiseDB: -100)
    let r = Measurement.process(recording: rec, plan: plan)
    check("\(s.method.rawValue): onset", abs(r.delaySamples - delay - 200) <= 2, "got \(r.delaySamples)")
    let got = Processing.slice(r.ir, start: delay + 200 - r.delaySamples + Measurement.preroll(fs), length: 6000)
    let e = errorDB(got, Array(cab[0..<6000]))
    check("\(s.method.rawValue): error < −40 dB", e < -40, String(format: "%.1f dB", e))
}

print("WAV")
do {
    var rng = SplitMix64(seed: 3)
    let x = (0..<1000).map { _ in rng.nextUnit() * 1.8 - 0.9 }
    let dir = FileManager.default.temporaryDirectory
    for (fmt, tol) in [(WavFormat.pcm16, 1.0 / 32000), (.pcm24, 1.0 / 8_000_000), (.float32, 1e-7)] {
        let url = dir.appendingPathComponent("ircore-test-\(fmt.rawValue).wav")
        try! WavFile.write(x, sampleRate: 44100, format: fmt, to: url)
        let d = try! WavFile.read(url)
        let err = zip(x, d.samples).map { abs($0 - $1) }.max() ?? 1
        check("\(fmt.label) round trip", d.samples.count == 1000 && d.sampleRate == 44100 && d.channels == 1 && err < tol,
              "err \(err)")
        try? FileManager.default.removeItem(at: url)
    }
    let h = WavFile.encode([0.5], sampleRate: 48000, format: .pcm24)
    check("24-bit header: PCM, mono, 48 kHz, 24 bits",
          h[20] == 1 && h[22] == 1 && h[24] == 0x80 && h[25] == 0xBB && h[34] == 24 && h.count == 44 + 3 + 1)
}

print("Processing")
do {
    let t = Processing.truncate(cab, length: 2048)
    check("truncate: exact length, fades to zero", t.count == 2048 && abs(t[2047]) < 1e-12 && t[0] == cab[0])

    let mp = Processing.minimumPhase(Array(cab[0..<4096]))
    let d = maxResponseDiff(mp, Array(cab[0..<4096]))
    check("minimum phase keeps the magnitude (±0.1 dB)", d < 0.1, String(format: "%.3f dB", d))
    let delayed = [Double](repeating: 0, count: 200) + Array(cab[0..<3896])
    let mpd = Processing.minimumPhase(delayed)
    check("minimum phase removes the pre-delay", Processing.onset(mpd) < 5, "onset \(Processing.onset(mpd))")

    let hp = Processing.highPass([1] + [Double](repeating: 0, count: 65535), cutoff: 20, sampleRate: fs)
    let c = Analysis.response(hp, sampleRate: fs, fMin: 10, fMax: 1000, minFFT: 65536)
    let at10 = c.dB.first!, at1k = c.dB.last!
    check("high-pass: −12 dB at 10 Hz, flat at 1 kHz", at10 < -11 && abs(at1k) < 0.05, "\(at10), \(at1k)")

    let rs = Processing.resample(Array(cab[0..<8192]), from: 48000, to: 44100)
    check("resample length", rs.count == Int((8192.0 * 44100 / 48000).rounded(.up)))
    // Different rates: compare on each file's own rate, absolute level included (IR gain must be kept).
    let ca = Analysis.response(rs, sampleRate: 44100, smoothing: 12, fMin: 50, fMax: 15000)
    let cb = Analysis.response(Array(cab[0..<8192]), sampleRate: 48000, smoothing: 12, fMin: 50, fMax: 15000)
    let worst = zip(ca.dB, cb.dB).map { abs($0 - $1) }.max() ?? 99
    check("resample 48 → 44.1 kHz keeps the response (±0.1 dB)", worst < 0.1, String(format: "%.3f dB", worst))

    let n = Processing.normalizedPeak(cab, dBFS: -0.1)
    check("normalise peak to −0.1 dBFS", abs(Analysis.dB(Processing.peak(n)) + 0.1) < 1e-9)
    let r = Processing.normalizedRMS(Array(cab[0..<2048]), dBFS: -24)
    check("matched RMS never exceeds −0.1 dBFS peak", Processing.peak(r) <= pow(10, -0.1 / 20) + 1e-12)
}

print("Export")
do {
    var opts = ExportOptions()
    for p in ExportPreset.all {
        let out = ExportRenderer.render(cab, masterRate: fs, preset: p, options: opts)
        check("\(p.platform) \(p.label): \(p.length) samples at \(p.sampleRate) Hz",
              out.count == p.length && abs(Analysis.dB(Processing.peak(out)) + 0.1) < 1e-6)
    }
    opts.minimumPhase = true
    let mp = ExportRenderer.render(cab, masterRate: fs, preset: ExportPreset.all[0], options: opts)
    check("minimum-phase export", mp.count == 1024 && mp.allSatisfy { $0.isFinite })
    check("file suffixes", ExportPreset.all[0].fileSuffix == "48k_1024" && ExportPreset.all.last!.fileSuffix == "44k1_4096")
    check("sanitize", ExportRenderer.sanitize("V30 / SM57 cap-edge") == "V30___SM57_cap-edge")
}

print("Analysis")
do {
    let c = Analysis.response(cab, sampleRate: fs, smoothing: 6)
    check("smoothed response finite", c.dB.allSatisfy { $0.isFinite } && c.frequencies.count == 512)
    let sg = Analysis.spectrogram(Signals.logSweep(f1: 20, f2: 20000, seconds: 2, sampleRate: fs), sampleRate: fs,
                                  columns: 100, rows: 50)
    check("spectrogram size", sg.values.count == sg.rows * sg.columns && sg.columns == 100)
}

print("Alignment")
do {
    let a = Array(cab[0..<4096])
    let fracShift = Alignment.shift(a, by: 7.3)
    let back = Alignment.shift(fracShift, by: -7.3)
    check("fractional shift round trip < −60 dB", errorDB(Array(back[0..<4000]), Array(a[0..<4000])) < -60,
          String(format: "%.1f dB", errorDB(Array(back[0..<4000]), Array(a[0..<4000]))))
    // A second "mic": the cab through a different EQ, 7.3 samples later, inverted.
    var other = Biquad.peaking(f: 3000, q: 1, gainDB: 4, fs: fs)
    let b = Alignment.shift(other.run(a), by: 7.3).map { -$0 }
    let r = Alignment.analyze(reference: a, b, sampleRate: fs)
    check("detects delay (−7.3 samples to align)", abs(r.shift + 7.3) < 0.15, String(format: "%.3f", r.shift))
    check("detects inverted polarity", r.inverted)
    check("high correlation", r.correlation > 0.9, String(format: "%.3f", r.correlation))
    let aligned = Alignment.apply(reference: a, others: [b], results: [r], flipPolarity: [true])
    let rb = Alignment.analyze(reference: aligned[0], aligned[1], sampleRate: fs)
    check("after alignment: no residual shift, normal polarity", abs(rb.shift) < 0.15 && !rb.inverted,
          String(format: "%.3f %@", rb.shift, rb.inverted ? "inv" : "norm"))
    // The aligned blend has no comb cancellation: its low-mid level beats the misaligned one.
    let bad = Alignment.blend([a, b], weights: [1, 1]), good = Alignment.blend(aligned, weights: [1, 1])
    func lowMid(_ h: [Double]) -> Double {
        let c = Analysis.response(h, sampleRate: fs, smoothing: 3, fMin: 200, fMax: 3000)
        return c.dB.reduce(0, +) / Double(c.dB.count)
    }
    check("aligned blend keeps its low mids", lowMid(good) - lowMid(bad) > 6,
          String(format: "%.1f vs %.1f dB", lowMid(good), lowMid(bad)))
}

print("Mic swap")
do {
    let sm57 = MicLibrary.builtIn.first { $0.id == "sm57" }!
    let r121 = MicLibrary.builtIn.first { $0.id == "r121" }!
    var o = MicSwap.Options()
    o.fLow = 20; o.fHigh = 20000; o.maxBoostDB = 30; o.maxCutDB = 30
    let speaker = Array(cab[0..<8192])
    // Simulate a capture: speaker through the SM57 (from flat), then remove the SM57 again.
    let withMic = MicSwap.apply(speaker, sampleRate: fs, source: MicLibrary.flat, target: sm57, options: o)
    let removed = MicSwap.apply(withMic, sampleRate: fs, source: sm57, target: nil, options: o)
    // Flat has no proximity (omni); the SM57 removal also removes its proximity bass, so compare above 400 Hz.
    let d1 = maxResponseDiff(removed, speaker, lo: 400, hi: 12000)
    check("SM57 applied then removed ≈ speaker (±0.5 dB, 400 Hz–12 kHz)", d1 < 0.5, String(format: "%.3f dB", d1))
    let swapped = MicSwap.apply(withMic, sampleRate: fs, source: sm57, target: r121, options: o)
    let direct = MicSwap.apply(speaker, sampleRate: fs, source: MicLibrary.flat, target: r121, options: o)
    let d2 = maxResponseDiff(swapped, direct, lo: 400, hi: 12000)
    check("SM57 → R-121 ≈ R-121 directly (±0.5 dB)", d2 < 0.5, String(format: "%.3f dB", d2))
    let p25 = MicSwap.proximityDB(100, pattern: .cardioid, distance: 0.025)
    check("cardioid proximity ≈ +8 dB at 100 Hz, 25 mm", abs(p25 - 8) < 1.5, String(format: "%.1f dB", p25))
    check("omni has no proximity", MicSwap.proximityDB(100, pattern: .omni, distance: 0.01) == 0)
    let h = MicSwap.filter(source: sm57, target: nil, options: MicSwap.Options(), sampleRate: fs)
    check("correction filter is minimum phase (energy at the start)", Processing.peakIndex(h) < 20, "peak \(Processing.peakIndex(h))")
    let c = MicCurve.parse("* REW export\nFreq(Hz) SPL(dB) Phase\n20, -3, 0\n1000\t0\t0\n10000;2;0\n", name: "Mine")
    check("parses REW/CSV curves", c?.points.count == 3 && abs((c?.dB(at: 10000) ?? 0) - 2) < 1e-9)
    check("curves normalised to 0 dB at 1 kHz", abs(sm57.dB(at: 1000)) < 1e-12)
}

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
