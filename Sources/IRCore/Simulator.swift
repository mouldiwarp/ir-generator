import Foundation

/// Synthetic cab and recording, for the offline tests and the app's demo/snapshot mode.
public enum Simulator {
    /// A plausible 4×12-ish cab + dynamic mic: resonant low end around 100 Hz, presence bump, steep top roll-off,
    /// and a weak reflection.
    public static func cabIR(sampleRate fs: Double, length: Int = 16384, delay: Int = 0, variant: Int = 0) -> [Double] {
        var x = [Double](repeating: 0, count: length)
        guard delay < length else { return x }
        x[delay] = 1
        let v = Double(variant)
        let reflection = delay + Int((0.0028 + 0.0007 * v) * fs)
        if reflection < length { x[reflection] = 0.22 }
        var b = Biquad.highPass(f: 85 + 10 * v, q: 1.6, fs: fs); x = b.run(x)
        b = Biquad.peaking(f: 2600 - 300 * v, q: 1.2, gainDB: 6 + v, fs: fs); x = b.run(x)
        b = Biquad.peaking(f: 650, q: 1.5, gainDB: -4, fs: fs); x = b.run(x)
        b = Biquad.lowPass(f: 5200 - 600 * v, q: 0.9, fs: fs); x = b.run(x)
        b = Biquad.lowPass(f: 6500 - 600 * v, q: 0.6, fs: fs); x = b.run(x)
        return x
    }

    /// Plays `plan.playback` through `ir`, adds `latency` samples of delay and white noise at `noiseDB` (dBFS RMS),
    /// with optional soft-clipping (`drive` > 0) to imitate a power amp's harmonic distortion.
    public static func record(_ plan: MeasurementPlan, through ir: [Double], latency: Int, level: Double = 0.3,
                              noiseDB: Double = -90, drive: Double = 0, seed: UInt64 = 7) -> [Double] {
        var src = plan.playback.map { $0 * level }
        if drive > 0 { src = src.map { tanh(drive * $0) / tanh(drive) } }
        let y = convolve(src, ir)
        var rng = SplitMix64(seed: seed)
        let noise = pow(10, noiseDB / 20)
        var rec = [Double](repeating: 0, count: plan.recordFrames)
        for i in 0..<rec.count {
            let j = i - latency
            rec[i] = (j >= 0 && j < y.count ? y[j] : 0) + noise * rng.nextGaussian()
        }
        return rec
    }

    public static func convolve(_ a: [Double], _ b: [Double]) -> [Double] { Processing.convolve(a, b) }
}

/// RBJ audio-EQ-cookbook biquad.
public struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    public static func lowPass(f: Double, q: Double, fs: Double) -> Biquad {
        let w = 2 * .pi * f / fs, al = sin(w) / (2 * q), c = cos(w)
        return Biquad(n: [(1 - c) / 2, 1 - c, (1 - c) / 2], d: [1 + al, -2 * c, 1 - al])
    }
    public static func highPass(f: Double, q: Double, fs: Double) -> Biquad {
        let w = 2 * .pi * f / fs, al = sin(w) / (2 * q), c = cos(w)
        return Biquad(n: [(1 + c) / 2, -(1 + c), (1 + c) / 2], d: [1 + al, -2 * c, 1 - al])
    }
    public static func peaking(f: Double, q: Double, gainDB: Double, fs: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * .pi * f / fs, al = sin(w) / (2 * q), c = cos(w)
        return Biquad(n: [1 + al * A, -2 * c, 1 - al * A], d: [1 + al / A, -2 * c, 1 - al / A])
    }

    init(n: [Double], d: [Double]) {
        b0 = n[0] / d[0]; b1 = n[1] / d[0]; b2 = n[2] / d[0]; a1 = d[1] / d[0]; a2 = d[2] / d[0]
    }

    public mutating func run(_ x: [Double]) -> [Double] {
        x.map { v in
            let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = y
            return y
        }
    }
}
