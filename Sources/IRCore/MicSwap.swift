import Foundation

public enum MicPattern: String, Codable, CaseIterable, Sendable {
    case omni, cardioid, supercardioid, hypercardioid, figure8

    public var label: String {
        switch self {
        case .omni: return "Omni"
        case .cardioid: return "Cardioid"
        case .supercardioid: return "Supercardioid"
        case .hypercardioid: return "Hypercardioid"
        case .figure8: return "Figure-8"
        }
    }

    /// Pressure-gradient share of the pattern, which sets the strength of the proximity effect.
    var gradient: Double {
        switch self {
        case .omni: return 0
        case .cardioid: return 0.5
        case .supercardioid: return 0.63
        case .hypercardioid: return 0.75
        case .figure8: return 1
        }
    }
}

/// An on-axis magnitude response, as (Hz, dB) breakpoints, measured or published at a distance where the
/// proximity effect is negligible.
public struct MicCurve: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var pattern: MicPattern
    public var points: [[Double]]
    public var builtIn: Bool

    public init(id: String, name: String, kind: String, pattern: MicPattern, points: [[Double]], builtIn: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.pattern = pattern
        self.points = points.filter { $0.count >= 2 && $0[0] > 0 }.sorted { $0[0] < $1[0] }
        self.builtIn = builtIn
    }

    /// dB at `f`: interpolated on log frequency, holding the end values outside the data, and normalised so
    /// 1 kHz = 0 dB.
    public func dB(at f: Double) -> Double { raw(f) - raw(1000) }

    private func raw(_ f: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if f <= first[0] { return first[1] }
        if f >= last[0] { return last[1] }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if points[m][0] <= f { lo = m } else { hi = m } }
        let (f0, d0, f1, d1) = (points[lo][0], points[lo][1], points[hi][0], points[hi][1])
        let t = log(f / f0) / log(f1 / f0)
        return d0 + (d1 - d0) * t
    }

    /// Parses a text response file: one "frequency dB [phase]" per line, separated by spaces, tabs, commas or
    /// semicolons (REW/FRD/CSV). Header and comment lines are skipped.
    public static func parse(_ text: String, name: String, pattern: MicPattern = .cardioid) -> MicCurve? {
        var pts: [[Double]] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("*") || t.hasPrefix("#") || t.hasPrefix("//") { continue }
            let fields = t.split(whereSeparator: { " \t,;".contains($0) }).compactMap { Double($0) }
            if fields.count >= 2, fields[0] > 0, fields[0] < 100_000, fields[1].isFinite { pts.append([fields[0], fields[1]]) }
        }
        guard pts.count >= 3 else { return nil }
        return MicCurve(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: name, kind: "Imported",
                        pattern: pattern, points: pts)
    }
}

/// Built-in approximate responses of common guitar-cab mics. These are smoothed approximations of the
/// published on-axis curves, not manufacturer data: units vary, and placement matters more. Import measured
/// or official curves where accuracy matters.
public enum MicLibrary {
    private static func mic(_ id: String, _ name: String, _ kind: String, _ p: MicPattern, _ pts: [(Double, Double)]) -> MicCurve {
        MicCurve(id: id, name: name, kind: kind, pattern: p, points: pts.map { [$0.0, $0.1] }, builtIn: true)
    }

    public static let flat = mic("flat", "Flat (measurement mic)", "Reference", .omni, [(20, 0), (20000, 0)])

    public static let builtIn: [MicCurve] = [
        mic("sm57", "Shure SM57", "Dynamic", .cardioid, [
            (20, -18), (40, -12), (50, -9), (70, -5), (100, -3), (150, -1.5), (200, -1), (300, -0.5), (500, 0),
            (1000, 0), (2000, 1), (3000, 2), (4000, 3.5), (5000, 5), (6000, 5.5), (7000, 4), (8000, 3.5),
            (9000, 4), (10000, 3), (12000, 0), (15000, -4), (20000, -12)]),
        mic("md421", "Sennheiser MD 421", "Dynamic", .cardioid, [
            (20, -12), (40, -6), (50, -4), (100, -1), (200, 0), (500, 0), (1000, 0), (2000, 1), (3000, 2),
            (4000, 3), (5000, 4), (6000, 3), (8000, 2), (10000, 1), (12000, -1), (15000, -4), (20000, -10)]),
        mic("e906", "Sennheiser e906", "Dynamic", .supercardioid, [
            (20, -15), (40, -8), (50, -6), (100, -2), (200, 0), (500, 0), (1000, 0), (2000, 1), (3000, 3),
            (4000, 4), (5000, 4), (6000, 3), (8000, 1), (10000, 0), (12000, -3), (15000, -8), (20000, -15)]),
        mic("i5", "Audix i5", "Dynamic", .cardioid, [
            (20, -15), (40, -8), (50, -6), (100, -2), (200, -1), (500, 0), (1000, 0), (2000, 0.5), (3000, 2),
            (4000, 3), (5000, 4), (6000, 4), (8000, 3), (10000, 2), (12000, -1), (15000, -6), (20000, -14)]),
        mic("re20", "Electro-Voice RE20", "Dynamic", .cardioid, [
            (20, -8), (40, -3), (50, -2), (100, 0), (1000, 0), (3000, 0), (5000, -0.5), (8000, -1.5),
            (10000, -3), (15000, -8), (20000, -14)]),
        mic("sm7b", "Shure SM7B", "Dynamic", .cardioid, [
            (20, -10), (40, -5), (50, -3), (100, -1), (200, 0), (1000, 0), (2000, 0.5), (3000, 1.5),
            (4000, 2.5), (5000, 3), (6000, 2.5), (8000, 1), (10000, -1), (15000, -8), (20000, -15)]),
        mic("r121", "Royer R-121", "Ribbon", .figure8, [
            (20, -6), (40, -2), (50, -1), (100, 0), (200, 0), (500, 0), (1000, 0), (2000, -0.5), (3000, -1),
            (4000, -2), (5000, -3), (6000, -4), (8000, -6), (10000, -8), (12000, -10), (15000, -14), (20000, -20)]),
        mic("m160", "Beyerdynamic M 160", "Ribbon", .hypercardioid, [
            (20, -10), (40, -5), (100, -1), (200, 0), (1000, 0), (3000, -1), (5000, -2), (8000, -4),
            (10000, -6), (15000, -10), (20000, -16)]),
        mic("c414", "AKG C414 (cardioid)", "Condenser", .cardioid, [
            (20, -2), (40, -1), (100, 0), (1000, 0), (3000, 0.5), (5000, 1), (8000, 2), (10000, 2.5),
            (12000, 2), (15000, 0), (20000, -3)]),
        mic("u87", "Neumann U 87 (cardioid)", "Condenser", .cardioid, [
            (20, -4), (40, -1.5), (100, 0), (1000, 0), (3000, 0), (5000, 1), (8000, 2), (10000, 1.5),
            (12000, 1), (15000, -1), (20000, -5)]),
        flat,
    ]
}

/// Removes one mic's response from an IR and optionally applies another's, as a minimum-phase correction
/// filter (real mics are close to minimum phase, so this keeps the transient intact).
public enum MicSwap {
    public struct Options: Codable, Hashable, Sendable {
        /// Mic-to-grille distance in metres, for the proximity (bass) effect of directional mics.
        public var distance: Double = 0.025
        public var maxBoostDB: Double = 12
        public var maxCutDB: Double = 24
        /// The correction fades to 0 dB below and above these.
        public var fLow: Double = 35
        public var fHigh: Double = 16000
        public init() {}
    }

    /// Bass lift (dB) of a pattern at a distance, relative to the far field. First-order gradient model,
    /// scaled to match typical published close-distance curves (about +8 dB at 100 Hz, 25 mm, cardioid).
    public static func proximityDB(_ f: Double, pattern: MicPattern, distance: Double) -> Double {
        guard pattern.gradient > 0, distance > 0, f > 0 else { return 0 }
        let k = 2 * .pi * f / 343
        let x = 0.21 * pattern.gradient / (k * distance)
        return 10 * log10(1 + x * x)
    }

    /// Correction in dB at `f`: target (with its proximity) minus source (with its proximity), limited and
    /// faded out at the band edges. `target == nil` removes the mic entirely ("speaker only").
    public static func correctionDB(_ f: Double, source: MicCurve, target: MicCurve?, options o: Options) -> Double {
        let s = source.dB(at: f) + proximityDB(f, pattern: source.pattern, distance: o.distance)
        let t = target.map { $0.dB(at: f) + proximityDB(f, pattern: $0.pattern, distance: o.distance) } ?? 0
        var d = max(-o.maxCutDB, min(o.maxBoostDB, t - s))
        // Fade to 0 dB over an octave outside the working band.
        if f < o.fLow { d *= max(0, 1 - log2(o.fLow / f)) }
        if f > o.fHigh { d *= max(0, 1 - log2(f / o.fHigh)) }
        return d
    }

    /// The correction, smoothed over 1/6 octave (imported curves can be ragged), on a log grid.
    public static func correctionCurve(source: MicCurve, target: MicCurve?, options: Options,
                                       fMin: Double = 10, fMax: Double = 24000, points: Int = 600) -> Analysis.Curve {
        let ratio = pow(fMax / fMin, 1 / Double(points - 1))
        let freqs = (0..<points).map { fMin * pow(ratio, Double($0)) }
        let raw = freqs.map { correctionDB($0, source: source, target: target, options: options) }
        let half = max(1, Int((1.0 / 12) / log2(ratio)))       // ±1/12 octave
        var out = raw
        for i in 0..<points {
            let a = max(0, i - half), b = min(points - 1, i + half)
            out[i] = raw[a...b].reduce(0, +) / Double(b - a + 1)
        }
        return Analysis.Curve(frequencies: freqs, dB: out)
    }

    /// Minimum-phase FIR realising the correction at `fs`.
    public static func filter(source: MicCurve, target: MicCurve?, options: Options, sampleRate fs: Double,
                              size: Int = 16384) -> [Double] {
        let curve = correctionCurve(source: source, target: target, options: options, fMin: 5, fMax: max(24000, fs / 2))
        let lf = curve.frequencies.map { log($0) }
        func dB(_ f: Double) -> Double {
            let x = log(max(f, curve.frequencies[0]))
            if x >= lf.last! { return curve.dB.last! }
            var lo = 0, hi = lf.count - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if lf[m] <= x { lo = m } else { hi = m } }
            let t = (x - lf[lo]) / (lf[hi] - lf[lo])
            return curve.dB[lo] + (curve.dB[hi] - curve.dB[lo]) * t
        }
        let fft = FFT(size: size)
        var mag = [Double](repeating: 1, count: size)
        for k in 0...(size / 2) {
            let v = pow(10, dB(Double(k) * fs / Double(size)) / 20)
            mag[k] = v
            if k > 0 && k < size / 2 { mag[size - k] = v }
        }
        var h = Array(Processing.minimumPhase(magnitude: mag, fft: fft)[0..<(size / 2)])
        Processing.fadeOut(&h, samples: size / 16)
        return h
    }

    /// The IR with the correction applied, same length.
    public static func apply(_ ir: [Double], sampleRate fs: Double, source: MicCurve, target: MicCurve?,
                             options: Options) -> [Double] {
        let h = filter(source: source, target: target, options: options, sampleRate: fs)
        var y = Array(Processing.convolve(ir, h)[0..<ir.count])
        Processing.fadeOut(&y, samples: max(8, ir.count / 20))
        return y
    }
}
