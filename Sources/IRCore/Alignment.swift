import Foundation

/// Phase alignment of IRs for blending: band-limited cross-correlation with sub-sample precision and polarity
/// detection, fractional-delay shifting, and weighted blends.
public enum Alignment {
    public struct Result: Sendable, Hashable {
        /// Samples to delay the IR by (negative = advance) so it lines up with the reference.
        public var shift: Double
        /// The IR correlates best with inverted polarity.
        public var inverted: Bool
        /// Normalised band-limited correlation at the best lag, 0…1.
        public var correlation: Double
    }

    /// Finds the shift and polarity that make `ir` sum best with `reference` in `band`
    /// (where blend cancellation is audible), searching ±`maxShiftMS`.
    public static func analyze(reference a: [Double], _ b: [Double], sampleRate fs: Double,
                               band: ClosedRange<Double> = 80...4000, maxShiftMS: Double = 5) -> Result {
        let n = FFT.size(atLeast: a.count + b.count)
        let fft = FFT(size: n)
        let A = fft.forward(real: a), B = fft.forward(real: b)
        var re = [Double](repeating: 0, count: n), im = re
        var ea = 0.0, eb = 0.0
        for k in 0..<n {
            let kk = k <= n / 2 ? k : n - k
            let w = bandWeight(Double(kk) * fs / Double(n), band)
            guard w > 0 else { continue }
            // A · conj(B) · W
            re[k] = (A.re[k] * B.re[k] + A.im[k] * B.im[k]) * w
            im[k] = (A.im[k] * B.re[k] - A.re[k] * B.im[k]) * w
            ea += (A.re[k] * A.re[k] + A.im[k] * A.im[k]) * w
            eb += (B.re[k] * B.re[k] + B.im[k] * B.im[k]) * w
        }
        // r[τ] = Σ a[m+τ]·b[m]: a peak at τ > 0 means `a` is `b` delayed by τ, so delay `b` by τ.
        let r = fft.inverseReal(re, im)
        let norm = sqrt(ea * eb) / Double(n)
        let maxLag = min(n / 2 - 2, Int(maxShiftMS / 1000 * fs))
        func at(_ lag: Int) -> Double { r[(lag + n) % n] }
        var best = 0, bestV = 0.0
        for lag in -maxLag...maxLag where abs(at(lag)) > abs(bestV) { best = lag; bestV = at(lag) }
        // Parabolic interpolation on the (sign-corrected) peak.
        let s = bestV < 0 ? -1.0 : 1.0
        let y0 = s * at(best - 1), y1 = s * at(best), y2 = s * at(best + 1)
        let den = y0 - 2 * y1 + y2
        let frac = abs(den) > 1e-30 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / den)) : 0
        let peak = y1 - 0.25 * (y0 - y2) * frac
        return Result(shift: Double(best) + frac, inverted: bestV < 0,
                      correlation: norm > 0 ? min(1, peak / norm) : 0)
    }

    /// Fractional delay by a linear phase ramp. Same length; content shifted past either end is dropped.
    public static func shift(_ x: [Double], by d: Double) -> [Double] {
        guard d != 0, !x.isEmpty else { return x }
        let pad = Int(abs(d).rounded(.up)) + 64
        let n = FFT.size(atLeast: x.count + 2 * pad)
        let fft = FFT(size: n)
        // Place x after `pad` zeros so an advance doesn't wrap into the end.
        var buf = [Double](repeating: 0, count: n)
        for i in 0..<x.count { buf[pad + i] = x[i] }
        var (re, im) = fft.forward(real: buf)
        for k in 0..<n {
            let kk = k <= n / 2 ? Double(k) : Double(k - n)
            let ph = -2 * .pi * kk * d / Double(n)
            let c = cos(ph), s = sin(ph)
            if k == n / 2 { re[k] *= c; im[k] = 0; continue }      // keep Nyquist real
            let r = re[k] * c - im[k] * s, i = re[k] * s + im[k] * c
            re[k] = r; im[k] = i
        }
        let y = fft.inverseReal(re, im)
        return Array(y[pad..<(pad + x.count)])
    }

    /// Weighted sum of IRs (zero-padded to the longest), scaled so the weights sum to 1.
    public static func blend(_ irs: [[Double]], weights: [Double]) -> [Double] {
        let n = irs.map(\.count).max() ?? 0
        let total = weights.reduce(0, +)
        guard n > 0, total > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        for (h, w) in zip(irs, weights) {
            let g = w / total
            for i in 0..<h.count { out[i] += h[i] * g }
        }
        return out
    }

    /// Applies analysis results to a set of IRs with the reference first. All shifts are offset together so
    /// none needs to advance past the IRs' short pre-roll (`headroom` samples), keeping every onset intact.
    public static func apply(reference: [Double], others: [[Double]], results: [Result], flipPolarity: [Bool],
                             headroom: Int = 8) -> [[Double]] {
        let shifts = [0.0] + results.map(\.shift)
        let offset = max(0, -(shifts.min() ?? 0) - Double(headroom))
        var out = [shift(reference, by: offset)]
        for (i, h) in others.enumerated() {
            var y = shift(h, by: results[i].shift + offset)
            if flipPolarity[i] { y = y.map { -$0 } }
            out.append(y)
        }
        return out
    }

    /// Raised-cosine band weight with half-octave skirts.
    static func bandWeight(_ f: Double, _ band: ClosedRange<Double>) -> Double {
        guard f > 0 else { return 0 }
        let skirt = 0.5
        if f < band.lowerBound {
            let o = log2(band.lowerBound / f)
            return o >= skirt ? 0 : 0.5 + 0.5 * cos(.pi * o / skirt)
        }
        if f > band.upperBound {
            let o = log2(f / band.upperBound)
            return o >= skirt ? 0 : 0.5 + 0.5 * cos(.pi * o / skirt)
        }
        return 1
    }
}
