import Foundation

/// Measurements and plot data.
public enum Analysis {
    public struct Curve: Sendable {
        public var frequencies: [Double]
        public var dB: [Double]

        public init(frequencies: [Double], dB: [Double]) {
            self.frequencies = frequencies
            self.dB = dB
        }
    }

    public static func dB(_ v: Double) -> Double { v > 0 ? 20 * log10(v) : -200 }

    /// Magnitude response on a log-frequency grid.
    /// - Parameter smoothing: fractional-octave width (3 = 1/3 octave), or nil for none (each point then averages
    ///   only the bins between it and its neighbours).
    public static func response(_ h: [Double], sampleRate fs: Double, smoothing: Double? = nil, points: Int = 512,
                                fMin: Double = 20, fMax: Double = 20000, minFFT: Int = 32768) -> Curve {
        let n = FFT.size(atLeast: max(h.count, minFFT))
        let H = FFT(size: n).forward(real: h)
        let nb = n / 2 + 1
        var pw = [Double](repeating: 0, count: nb)
        for k in 0..<nb { pw[k] = H.re[k] * H.re[k] + H.im[k] * H.im[k] }
        // Prefix sums for fast band averages.
        var prefix = [Double](repeating: 0, count: nb + 1)
        for k in 0..<nb { prefix[k + 1] = prefix[k] + pw[k] }
        let binHz = fs / Double(n)
        let top = min(fMax, fs / 2)
        let ratio = pow(top / fMin, 1 / Double(points - 1))
        let halfWidth = smoothing.map { pow(2, 0.5 / $0) } ?? sqrt(ratio)
        var freqs = [Double](repeating: 0, count: points), out = freqs
        for i in 0..<points {
            let f = fMin * pow(ratio, Double(i))
            freqs[i] = f
            // Average power over [lo, hi] in bins, integrating fractional bins (bin k covers k ± 0.5),
            // so narrow low-frequency windows don't snap to whole bins.
            let lo = f / halfWidth / binHz, hi = f * halfWidth / binHz
            func cumulative(_ x: Double) -> Double {
                let y = min(max(x + 0.5, 0), Double(nb))
                let k = Int(y)
                return prefix[k] + (k < nb ? (y - Double(k)) * pw[k] : 0)
            }
            let p = (cumulative(hi) - cumulative(lo)) / max(hi - lo, 1e-9)
            out[i] = 10 * log10(max(p, 1e-30))
        }
        return Curve(frequencies: freqs, dB: out)
    }

    /// Peak-to-noise ratio of a full-length IR: the peak against the RMS of a window well after the direct sound,
    /// where a speaker cab has decayed into the measurement's noise floor.
    public static func peakToNoise(_ h: [Double], onset: Int, sampleRate fs: Double) -> Double {
        guard !h.isEmpty else { return 0 }
        let start = onset + Int(0.5 * fs), len = Int(0.25 * fs)
        var s = 0.0
        for i in 0..<len { let v = h[(start + i) % h.count]; s += v * v }
        let rms = sqrt(s / Double(len))
        return dB(Processing.peak(h)) - dB(rms)
    }

    /// Short-time magnitude spectrum, `rows` log-spaced bands × `columns` frames, in dB relative to the maximum
    /// (row 0 = fMin). Values are clamped to `floorDB`…0.
    public struct Spectrogram: Sendable {
        public var rows: Int
        public var columns: Int
        public var values: [Float]      // row-major, rows × columns
        public var duration: Double
        public var fMin: Double
        public var fMax: Double
    }

    public static func spectrogram(_ x: [Double], sampleRate fs: Double, columns: Int = 480, rows: Int = 200,
                                   fMin: Double = 20, fMax: Double = 20000, fftSize: Int = 4096,
                                   floorDB: Float = -100) -> Spectrogram {
        let n = fftSize
        let fft = FFT(size: n)
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n)) }
        let top = min(fMax, fs / 2)
        let hop = max(1, (x.count - n) / max(1, columns - 1))
        let cols = max(1, min(columns, (x.count - n) / hop + 1))
        var vals = [Float](repeating: floorDB, count: rows * cols)
        // Bin range for each row.
        let ratio = pow(top / fMin, 1 / Double(rows))
        let binHz = fs / Double(n)
        let edges = (0...rows).map { fMin * pow(ratio, Double($0)) / binHz }
        var maxV: Float = -.infinity
        for c in 0..<cols {
            let s = c * hop
            var re = [Double](repeating: 0, count: n), im = re
            for i in 0..<n where s + i < x.count { re[i] = x[s + i] * window[i] }
            fft.transform(&re, &im)
            for r in 0..<rows {
                let a = max(1, Int(edges[r])), b = max(a, min(n / 2, Int(edges[r + 1])))
                var p = 0.0
                for k in a...b { p = max(p, re[k] * re[k] + im[k] * im[k]) }
                let v = Float(10 * log10(max(p, 1e-30)))
                vals[r * cols + c] = v
                maxV = max(maxV, v)
            }
        }
        for i in 0..<vals.count { vals[i] = max(floorDB, vals[i] - maxV) }
        return Spectrogram(rows: rows, columns: cols, values: vals, duration: Double(x.count) / fs, fMin: fMin, fMax: top)
    }

    /// Min/max envelope of `x` in `buckets` columns, for drawing long waveforms.
    public static func envelope(_ x: [Double], buckets: Int) -> [(min: Double, max: Double)] {
        guard !x.isEmpty, buckets > 0 else { return [] }
        let per = Double(x.count) / Double(buckets)
        return (0..<buckets).map { b in
            let a = Int(Double(b) * per), e = max(a + 1, min(x.count, Int(Double(b + 1) * per)))
            var lo = Double.infinity, hi = -Double.infinity
            for i in a..<e { lo = min(lo, x[i]); hi = max(hi, x[i]) }
            return (lo, hi)
        }
    }
}
