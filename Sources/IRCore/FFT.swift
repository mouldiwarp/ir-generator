import Accelerate
import Foundation

/// Double-precision in-place complex FFT (power-of-two sizes) on top of vDSP.
public final class FFT {
    public let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    public init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        n = size
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    /// Smallest power of two ≥ `m`.
    public static func size(atLeast m: Int) -> Int {
        var n = 2
        while n < m { n <<= 1 }
        return n
    }

    /// Transforms (re, im) in place. Forward is unscaled; inverse is scaled by 1/n.
    public func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        precondition(re.count == n && im.count == n)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var s = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zipD(setup, &s, 1, log2n,
                              FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
        if inverse {
            var k = 1.0 / Double(n)
            vDSP_vsmulD(re, 1, &k, &re, 1, vDSP_Length(n))
            vDSP_vsmulD(im, 1, &k, &im, 1, vDSP_Length(n))
        }
    }

    /// Spectrum of a real signal, zero-padded (or truncated) to n.
    public func forward(real x: [Double]) -> (re: [Double], im: [Double]) {
        var re = [Double](repeating: 0, count: n)
        let m = min(x.count, n)
        re.withUnsafeMutableBufferPointer { r in
            x.withUnsafeBufferPointer { s in r.baseAddress!.update(from: s.baseAddress!, count: m) }
        }
        var im = [Double](repeating: 0, count: n)
        transform(&re, &im)
        return (re, im)
    }

    /// Real part of the inverse transform.
    public func inverseReal(_ re: [Double], _ im: [Double]) -> [Double] {
        var r = re, i = im
        transform(&r, &i, inverse: true)
        return r
    }
}

/// Complex helpers on split arrays.
enum Complex {
    /// |z|²
    static func power(_ re: [Double], _ im: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: re.count)
        for k in 0..<re.count { out[k] = re[k] * re[k] + im[k] * im[k] }
        return out
    }
}
