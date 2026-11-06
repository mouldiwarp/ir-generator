import Foundation

/// Turns a recorded response back into an impulse response.
public enum Deconvolver {
    /// Linear deconvolution by regularised spectral division:
    ///   H = Y·X* / (|X|² + ε(f))
    /// `excitation` is the whole playback block (including any leading silence), so the IR's lag is just the
    /// system's round-trip latency plus the acoustic delay. With a sine sweep, harmonic distortion lands at
    /// negative time, which wraps to the end of the result and is cut off when the IR is trimmed.
    /// - Returns: the full-length IR (FFT size), lag 0 first.
    public static func linear(response y: [Double], excitation x: [Double], sampleRate fs: Double,
                              band: ClosedRange<Double>) -> [Double] {
        let n = FFT.size(atLeast: x.count + y.count)
        let fft = FFT(size: n)
        let X = fft.forward(real: x), Y = fft.forward(real: y)
        return divide(Y, by: X, n: n, fft: fft, sampleRate: fs, band: band)
    }

    /// Circular deconvolution of one steady-state period (periodic noise): H = Y / X, regularised.
    public static func circular(responsePeriod y: [Double], excitationPeriod x: [Double], sampleRate fs: Double,
                                band: ClosedRange<Double>) -> [Double] {
        precondition(x.count == y.count)
        let n = x.count
        let fft = FFT(size: n)
        let X = fft.forward(real: x), Y = fft.forward(real: y)
        return divide(Y, by: X, n: n, fft: fft, sampleRate: fs, band: band)
    }

    /// Averages `count` consecutive periods of `period` samples starting at `start` (synchronous averaging).
    /// Uncorrelated noise drops by 10·log10(count) dB; the response is unchanged.
    public static func synchronousAverage(_ rec: [Double], start: Int, period: Int, count: Int) -> [Double] {
        var out = [Double](repeating: 0, count: period)
        var used = 0
        for k in 0..<count {
            let s = start + k * period
            guard s >= 0 else { continue }
            used += 1
            for i in 0..<period where s + i < rec.count { out[i] += rec[s + i] }
        }
        guard used > 0 else { return out }
        let g = 1 / Double(used)
        for i in 0..<period { out[i] *= g }
        return out
    }

    // MARK: -

    private static func divide(_ Y: (re: [Double], im: [Double]), by X: (re: [Double], im: [Double]), n: Int,
                               fft: FFT, sampleRate fs: Double, band: ClosedRange<Double>) -> [Double] {
        let pX = Complex.power(X.re, X.im)
        // Reference level: the strongest in-band bin.
        var maxPow = 0.0
        for k in 0...(n / 2) {
            let f = Double(k) * fs / Double(n)
            if band.contains(f) { maxPow = max(maxPow, pX[k]) }
        }
        if maxPow == 0 { maxPow = pX.max() ?? 1 }
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let kk = k <= n / 2 ? k : n - k
            let f = Double(kk) * fs / Double(n)
            let eps = maxPow * regularisation(f, band: band)
            // Y·X* / (|X|² + ε)
            let d = pX[k] + eps
            guard d > 0 else { continue }
            re[k] = (Y.re[k] * X.re[k] + Y.im[k] * X.im[k]) / d
            im[k] = (Y.im[k] * X.re[k] - Y.re[k] * X.im[k]) / d
        }
        return fft.inverseReal(re, im)
    }

    /// ε relative to the peak excitation power: tiny in band (about −80 dB), large out of band, with a
    /// smooth third-octave transition so the band edges don't ring.
    static func regularisation(_ f: Double, band: ClosedRange<Double>) -> Double {
        let inside = 1e-8, outside = 1.0
        let width = 1.0 / 3.0    // octaves
        func blend(_ octaves: Double) -> Double {   // 0 at the edge … 1 at `width` beyond it
            let t = min(1, max(0, octaves / width))
            let w = 0.5 - 0.5 * cos(.pi * t)
            return exp(log(inside) + (log(outside) - log(inside)) * w)
        }
        if f <= 0 { return outside }
        if f < band.lowerBound { return blend(log2(band.lowerBound / f)) }
        if f > band.upperBound { return blend(log2(f / band.upperBound)) }
        return inside
    }
}
