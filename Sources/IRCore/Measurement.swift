import Foundation

public enum MeasurementMethod: String, Codable, CaseIterable, Sendable {
    case sweep, pinkNoise, whiteNoise

    public var label: String {
        switch self {
        case .sweep: return "SINE SWEEP"
        case .pinkNoise: return "PINK NOISE"
        case .whiteNoise: return "WHITE NOISE"
        }
    }
}

/// Everything that defines one measurement. Stored with each capture.
public struct MeasurementSettings: Codable, Hashable, Sendable {
    public var method: MeasurementMethod = .sweep
    public var f1: Double = 20
    public var f2: Double = 20000
    public var sweepSeconds: Double = 4
    /// Sweeps (or noise periods) averaged together.
    public var averages: Int = 1
    public var preSilence: Double = 0.5
    /// Silence recorded after each sweep while the room and cab decay.
    public var tail: Double = 2
    /// Noise period = 2^noisePeriodLog2 samples (65536 ≈ 1.37 s at 48 kHz).
    public var noisePeriodLog2: Int = 16
    /// Length of the stored master IR.
    public var irSeconds: Double = 1
    public var highPass: Bool = true
    public var highPassHz: Double = 20
    public var sampleRate: Double = 48000

    public init() {}

    public var band: ClosedRange<Double> { f1...min(f2, sampleRate * 0.49) }
}

/// What to play and how long to record.
public struct MeasurementPlan: Sendable {
    public var settings: MeasurementSettings
    /// Full playback buffer, peak 1.0 (level is applied at playback).
    public var playback: [Double]
    /// One excitation period: a whole sweep block (silence + sweep + tail) or one noise period.
    public var excitation: [Double]
    public var period: Int
    /// Index of the first recorded period used for averaging.
    public var firstPeriod: Int
    public var recordFrames: Int { playback.count }
    public var duration: Double { Double(playback.count) / settings.sampleRate }
}

public struct MeasurementResult: Sendable {
    /// The trimmed master IR (`irSeconds` long), un-normalised.
    public var ir: [Double]
    /// The averaged response used for the deconvolution (for display).
    public var response: [Double]
    /// Samples from the start of playback to the direct sound (round-trip latency + acoustic delay).
    public var delaySamples: Int
    public var peakToNoiseDB: Double
    public var inputPeakDB: Double
    public var clipped: Bool
    /// The IR kept the acoustic delay after the calibrated latency. False when that wasn't asked for, or when
    /// the direct sound arrived before the calibrated latency (the USB round trip varies by about 1 ms between
    /// runs), in which case the IR starts at the direct sound instead so it isn't cut off.
    public var keptDelay: Bool
}

public enum Measurement {
    /// Samples kept before the direct sound (about 0.2 ms), faded in.
    public static func preroll(_ fs: Double) -> Int { max(4, Int(0.0002 * fs)) }

    public static func plan(_ s: MeasurementSettings) -> MeasurementPlan {
        let fs = s.sampleRate
        let extra = [Double](repeating: 0, count: Int(0.3 * fs))   // room for the latency at the end
        switch s.method {
        case .sweep:
            let sweep = Signals.logSweep(f1: s.f1, f2: min(s.f2, fs * 0.49), seconds: s.sweepSeconds, sampleRate: fs)
            let block = [Double](repeating: 0, count: Int(s.preSilence * fs)) + sweep
                + [Double](repeating: 0, count: Int(s.tail * fs))
            var play: [Double] = []
            for _ in 0..<max(1, s.averages) { play += block }
            return MeasurementPlan(settings: s, playback: play + extra, excitation: block, period: block.count, firstPeriod: 0)
        case .pinkNoise, .whiteNoise:
            let n = 1 << s.noisePeriodLog2
            let period = Signals.periodicNoise(length: n, sampleRate: fs, f1: s.f1, f2: min(s.f2, fs * 0.49),
                                               pink: s.method == .pinkNoise)
            // One settling period first, the averaged periods, then one more period to fade out on.
            var play: [Double] = []
            for _ in 0..<(max(1, s.averages) + 2) { play += period }
            Signals.applyFades(&play, fadeIn: Int(0.05 * fs), fadeOut: Int(0.05 * fs))
            let lead = [Double](repeating: 0, count: Int(0.1 * fs))
            return MeasurementPlan(settings: s, playback: lead + play + extra, excitation: period, period: n,
                                   firstPeriod: lead.count + n)
        }
    }

    /// Turns a recording (same length and clock as the playback) into an IR.
    /// - Parameters:
    ///   - latency: round-trip latency from a loopback calibration. With `keepDelay`, the IR keeps the acoustic
    ///     delay after that latency (for phase-aligning several mics); otherwise it starts at the direct sound.
    public static func process(recording rec: [Double], plan: MeasurementPlan, latency: Int? = nil,
                               keepDelay: Bool = false) -> MeasurementResult {
        let s = plan.settings, fs = s.sampleRate
        let peakIn = Processing.peak(rec)
        let avg = Deconvolver.synchronousAverage(rec, start: plan.firstPeriod, period: plan.period, count: max(1, s.averages))
        let full: [Double]
        switch s.method {
        case .sweep:
            full = Deconvolver.linear(response: avg, excitation: plan.excitation, sampleRate: fs, band: s.band)
        case .pinkNoise, .whiteNoise:
            full = Deconvolver.circular(responsePeriod: avg, excitationPeriod: plan.excitation, sampleRate: fs, band: s.band)
        }
        let onset = Processing.onset(full, searchLength: min(full.count, Int(0.4 * fs)))
        let pnr = Analysis.peakToNoise(full, onset: onset, sampleRate: fs)
        let preroll = preroll(fs)
        var start = onset - preroll
        var kept = false
        if keepDelay, let l = latency, l <= onset {
            start = l - preroll
            kept = true
        }
        var ir = Processing.slice(full, start: start, length: Int(s.irSeconds * fs))
        Processing.fadeIn(&ir, samples: min(preroll, max(0, onset - start)))
        if s.highPass { ir = Processing.highPass(ir, cutoff: s.highPassHz, sampleRate: fs) }
        Processing.fadeOut(&ir, samples: ir.count / 20)
        return MeasurementResult(ir: ir, response: avg, delaySamples: onset, peakToNoiseDB: pnr,
                                 inputPeakDB: Analysis.dB(peakIn), clipped: peakIn >= 0.989, keptDelay: kept)
    }
}
