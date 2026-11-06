import Foundation

/// Test signals. Every generator returns a signal with a peak of 1.0; the output level is applied at playback.
public enum Signals {
    /// Exponential (logarithmic) sine sweep, Farina's ESS:
    /// x(t) = sin(2π·f1·L·(e^(t/L) − 1)), with L = T / ln(f2/f1).
    /// Short raised-cosine fades at both ends keep the edges from clicking.
    public static func logSweep(f1: Double, f2: Double, seconds: Double, sampleRate fs: Double,
                                fadeIn: Double = 0.03, fadeOut: Double = 0.005) -> [Double] {
        let n = Int(seconds * fs)
        let L = seconds / log(f2 / f1)
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            x[i] = sin(2 * .pi * f1 * L * (exp(t / L) - 1))
        }
        applyFades(&x, fadeIn: Int(fadeIn * fs), fadeOut: Int(fadeOut * fs))
        return x
    }

    /// One period of band-limited periodic noise, built in the frequency domain:
    /// flat ("white") or −3 dB/octave ("pink") magnitude between f1 and f2 with random phase.
    /// Repeating it gives a steady-state signal whose spectrum has no gaps in the band,
    /// so the circular deconvolution is exact.
    public static func periodicNoise(length n: Int, sampleRate fs: Double, f1: Double, f2: Double,
                                     pink: Bool, seed: UInt64 = 0x5EED_1234) -> [Double] {
        precondition(n & (n - 1) == 0, "noise period must be a power of two")
        var rng = SplitMix64(seed: seed)
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        for k in 1..<(n / 2) {
            let f = Double(k) * fs / Double(n)
            guard f >= f1 && f <= f2 else { continue }
            let mag = pink ? 1 / sqrt(f) : 1
            let ph = rng.nextUnit() * 2 * .pi
            re[k] = mag * cos(ph); im[k] = mag * sin(ph)
            re[n - k] = re[k]; im[n - k] = -im[k]
        }
        var x = FFT(size: n).inverseReal(re, im)
        normalizePeak(&x)
        return x
    }

    /// Steady sine for level checks.
    public static func tone(frequency: Double, seconds: Double, sampleRate fs: Double) -> [Double] {
        // Whole number of cycles so the buffer loops without a click.
        let n = Int(seconds * fs)
        let cycles = max(1, (frequency * Double(n) / fs).rounded())
        return (0..<n).map { sin(2 * .pi * cycles * Double($0) / Double(n)) }
    }

    public static func applyFades(_ x: inout [Double], fadeIn: Int, fadeOut: Int) {
        let n = x.count
        for i in 0..<min(fadeIn, n) { x[i] *= 0.5 - 0.5 * cos(.pi * Double(i) / Double(fadeIn)) }
        for i in 0..<min(fadeOut, n) { x[n - 1 - i] *= 0.5 - 0.5 * cos(.pi * Double(i) / Double(fadeOut)) }
    }

    public static func normalizePeak(_ x: inout [Double], to peak: Double = 1) {
        let p = x.reduce(0) { max($0, abs($1)) }
        guard p > 0 else { return }
        let k = peak / p
        for i in 0..<x.count { x[i] *= k }
    }
}

/// Small deterministic PRNG (SplitMix64).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Standard normal (Box–Muller).
    public mutating func nextGaussian() -> Double {
        let u = max(nextUnit(), 1e-300), v = nextUnit()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}
