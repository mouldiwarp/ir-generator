import Foundation

/// Post-processing applied to a raw deconvolved IR.
public enum Processing {
    public static func peak(_ h: [Double]) -> Double { h.reduce(0) { max($0, abs($1)) } }

    public static func peakIndex(_ h: [Double], in range: Range<Int>? = nil) -> Int {
        let r = range ?? 0..<h.count
        var best = r.lowerBound, v = -1.0
        for i in r where abs(h[i]) > v { v = abs(h[i]); best = i }
        return best
    }

    /// First sample within `thresholdDB` of the peak: the direct-sound arrival.
    /// Only the first `searchLength` samples are searched, which keeps the (wrapped) sweep distortion
    /// products at the end of a full-length IR out of the way.
    public static func onset(_ h: [Double], thresholdDB: Double = -20, searchLength: Int? = nil) -> Int {
        let end = min(h.count, searchLength ?? h.count)
        guard end > 0 else { return 0 }
        let p = peakIndex(h, in: 0..<end)
        let thr = abs(h[p]) * pow(10, thresholdDB / 20)
        for i in 0...p where abs(h[i]) >= thr { return i }
        return p
    }

    /// `length` samples of `h` from `start` (zero-padded past the end). Negative starts wrap around, as in a
    /// circular IR.
    public static func slice(_ h: [Double], start: Int, length: Int) -> [Double] {
        var out = [Double](repeating: 0, count: length)
        for i in 0..<length {
            var j = start + i
            if j < 0 { j += h.count }
            if j >= 0 && j < h.count { out[i] = h[j] }
        }
        return out
    }

    public static func fadeIn(_ h: inout [Double], samples: Int) {
        guard samples > 0 else { return }
        for i in 0..<min(samples, h.count) { h[i] *= 0.5 - 0.5 * cos(.pi * Double(i) / Double(samples)) }
    }

    /// Half-Hann fade over the last `samples`, ending at exactly zero.
    public static func fadeOut(_ h: inout [Double], samples: Int) {
        let n = h.count
        guard samples > 0, n > 0 else { return }
        let m = min(samples, n)
        for i in 0..<m {
            let t = Double(i + 1) / Double(m)            // 1/m … 1 at the last sample
            h[n - m + i] *= 0.5 + 0.5 * cos(.pi * t)
        }
    }

    /// Cuts to `length` samples with a fade-out over the last `fadeFraction` of it.
    public static func truncate(_ h: [Double], length: Int, fadeFraction: Double = 0.1) -> [Double] {
        var out = slice(h, start: 0, length: length)
        fadeOut(&out, samples: max(8, Int(Double(length) * fadeFraction)))
        return out
    }

    /// Second-order Butterworth high-pass (RBJ biquad), e.g. to clear DC and sub-sonic rumble.
    public static func highPass(_ h: [Double], cutoff: Double, sampleRate fs: Double) -> [Double] {
        let w = 2 * .pi * cutoff / fs, q = 1 / sqrt(2.0)
        let alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha
        let b0 = (1 + c) / 2 / a0, b1 = -(1 + c) / a0, b2 = (1 + c) / 2 / a0
        let a1 = -2 * c / a0, a2 = (1 - alpha) / a0
        var out = [Double](repeating: 0, count: h.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<h.count {
            let x = h[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }

    /// Minimum-phase version with the same magnitude response (real-cepstrum folding).
    /// Moves all the energy to the front, which removes pre-delay and makes short truncations hold up better.
    public static func minimumPhase(_ h: [Double]) -> [Double] {
        let n = FFT.size(atLeast: h.count * 4)
        let fft = FFT(size: n)
        let H = fft.forward(real: h)
        let mag = Complex.power(H.re, H.im).map { sqrt($0) }
        return Array(minimumPhase(magnitude: mag, fft: fft)[0..<h.count])
    }

    /// Minimum-phase impulse response (length n) for a full, symmetric magnitude spectrum of length n.
    public static func minimumPhase(magnitude mag: [Double], fft: FFT) -> [Double] {
        let n = fft.n
        let floor = (mag.max() ?? 1) * 1e-6               // −120 dB floor keeps log() finite
        let logMag = mag.map { log(max($0, floor)) }
        // Real cepstrum
        var c = fft.inverseReal(logMag, [Double](repeating: 0, count: n))
        // Fold: keep c[0] and c[n/2], double the causal part, zero the anti-causal part.
        for i in 1..<(n / 2) { c[i] *= 2 }
        for i in (n / 2 + 1)..<n { c[i] = 0 }
        var cr = c, ci = [Double](repeating: 0, count: n)
        fft.transform(&cr, &ci)
        // exp(a + ib) = e^a (cos b + i sin b)
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let e = exp(cr[k])
            re[k] = e * cos(ci[k]); im[k] = e * sin(ci[k])
        }
        return fft.inverseReal(re, im)
    }

    /// Linear convolution (FFT), full length a.count + b.count − 1.
    public static func convolve(_ a: [Double], _ b: [Double]) -> [Double] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let n = FFT.size(atLeast: a.count + b.count)
        let fft = FFT(size: n)
        let A = fft.forward(real: a), B = fft.forward(real: b)
        var re = [Double](repeating: 0, count: n), im = re
        for k in 0..<n {
            re[k] = A.re[k] * B.re[k] - A.im[k] * B.im[k]
            im[k] = A.re[k] * B.im[k] + A.im[k] * B.re[k]
        }
        return Array(fft.inverseReal(re, im)[0..<(a.count + b.count - 1)])
    }

    public static func normalizedPeak(_ h: [Double], dBFS: Double = -0.1) -> [Double] {
        let p = peak(h)
        guard p > 0 else { return h }
        let k = pow(10, dBFS / 20) / p
        return h.map { $0 * k }
    }

    /// Scales so the IR's RMS over its length is `dBFS`. Different IRs then sit at similar loudness,
    /// but peaks are limited to −0.1 dBFS so the file can never clip.
    public static func normalizedRMS(_ h: [Double], dBFS: Double = -24) -> [Double] {
        guard !h.isEmpty else { return h }
        let rms = sqrt(h.reduce(0) { $0 + $1 * $1 } / Double(h.count))
        guard rms > 0 else { return h }
        var k = pow(10, dBFS / 20) / rms
        let p = peak(h) * k, ceiling = pow(10, -0.1 / 20)
        if p > ceiling { k *= ceiling / p }
        return h.map { $0 * k }
    }

    /// Band-limited resampling by windowed-sinc (Kaiser) interpolation. Exact for any rate pair, and cheap at
    /// IR lengths. With `impulse`, samples are scaled by from/to so the IR's filter gain is unchanged
    /// (an IR's frequency response is the sum over its samples, so fewer samples need proportionally more weight).
    public static func resample(_ x: [Double], from: Double, to: Double, impulse: Bool = true, halfTaps: Int = 48) -> [Double] {
        guard from != to, !x.isEmpty else { return x }
        let r = to / from
        let outLen = Int((Double(x.count) * r).rounded(.up))
        let fc = min(1, r) * 0.96          // cutoff relative to the input Nyquist
        let gain = impulse ? 1 / r : 1
        let beta = 8.6, i0b = besselI0(beta)
        var out = [Double](repeating: 0, count: outLen)
        for j in 0..<outLen {
            let t = Double(j) / r
            let base = Int(t.rounded(.down))
            var acc = 0.0
            for k in (base - halfTaps + 1)...(base + halfTaps) where k >= 0 && k < x.count {
                let d = t - Double(k)
                let u = d / Double(halfTaps)
                guard abs(u) <= 1 else { continue }
                let win = besselI0(beta * sqrt(1 - u * u)) / i0b
                let arg = .pi * fc * d
                let sinc = abs(arg) < 1e-12 ? 1 : sin(arg) / arg
                acc += x[k] * fc * sinc * win
            }
            out[j] = acc * gain
        }
        return out
    }

    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let q = x * x / 4
        for k in 1..<50 {
            term *= q / Double(k * k)
            sum += term
            if term < sum * 1e-16 { break }
        }
        return sum
    }
}
