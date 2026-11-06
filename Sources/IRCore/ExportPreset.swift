import Foundation

/// A target file format for a modeller.
public struct ExportPreset: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var platform: String
    public var label: String
    public var sampleRate: Int
    public var length: Int          // samples
    public var format: WavFormat
    public var detail: String

    public var milliseconds: Double { Double(length) / Double(sampleRate) * 1000 }

    /// e.g. "48k_2048" or "44k1_4096".
    public var fileSuffix: String {
        let k = sampleRate % 1000 == 0 ? "\(sampleRate / 1000)k" : String(format: "%dk%d", sampleRate / 1000, (sampleRate % 1000) / 100)
        return "\(k)_\(length)"
    }

    public static let fractal = "Fractal"
    public static let ik = "TONEX / AmpliTube"

    public static let all: [ExportPreset] = [
        ExportPreset(id: "fractal-1024", platform: fractal, label: "1024 · Standard", sampleRate: 48000, length: 1024,
                     format: .pcm24, detail: "21 ms. Axe-Fx III, FM9 and FM3 standard IR length."),
        ExportPreset(id: "fractal-2048", platform: fractal, label: "2048", sampleRate: 48000, length: 2048,
                     format: .pcm24, detail: "43 ms. Keeps more low-end detail."),
        ExportPreset(id: "fractal-8192", platform: fractal, label: "8192 · UltraRes", sampleRate: 48000, length: 8192,
                     format: .pcm24, detail: "171 ms. Axe-Fx III / FM9 UltraRes. Import with Fractal-Bot or Axe-Edit."),
        ExportPreset(id: "ik-2048", platform: ik, label: "2048", sampleRate: 48000, length: 2048,
                     format: .pcm24, detail: "43 ms. Lightest on CPU."),
        ExportPreset(id: "ik-4096", platform: ik, label: "4096", sampleRate: 48000, length: 4096,
                     format: .pcm24, detail: "85 ms. A good default for TONEX and AmpliTube."),
        ExportPreset(id: "ik-8192", platform: ik, label: "8192", sampleRate: 48000, length: 8192,
                     format: .pcm24, detail: "171 ms. Full cab resonance."),
        ExportPreset(id: "ik-500ms", platform: ik, label: "500 ms", sampleRate: 48000, length: 24000,
                     format: .pcm24, detail: "Long IR with some of the room."),
        ExportPreset(id: "ik-4096-44k", platform: ik, label: "4096 · 44.1 kHz", sampleRate: 44100, length: 4096,
                     format: .pcm24, detail: "For sessions running at 44.1 kHz."),
    ]
}

public enum Normalization: String, Codable, CaseIterable, Sendable {
    case peak, rms, none

    public var label: String {
        switch self {
        case .peak: return "PEAK −0.1 dB"
        case .rms: return "MATCHED RMS"
        case .none: return "NONE"
        }
    }
}

public struct ExportOptions: Codable, Hashable, Sendable {
    public var normalization: Normalization = .peak
    public var minimumPhase = false
    public var fadeFraction = 0.1
    /// High-cut (24 dB/octave) frequency; nil or 0 = off. Optional so older saved settings still decode.
    public var highCutHz: Double?
    public init() {}

    public var highCut: Double { highCutHz ?? 0 }
}

public enum ExportRenderer {
    /// Master IR → file samples: optional minimum phase, resample, truncate with fade, normalise.
    public static func render(_ master: [Double], masterRate: Double, sampleRate: Int, length: Int,
                              options: ExportOptions) -> [Double] {
        var h = master
        if options.minimumPhase { h = Processing.minimumPhase(h) }
        if Double(sampleRate) != masterRate { h = Processing.resample(h, from: masterRate, to: Double(sampleRate)) }
        if options.highCut > 0 { h = Processing.lowPass(h, cutoff: options.highCut, sampleRate: Double(sampleRate)) }
        h = Processing.truncate(h, length: length, fadeFraction: options.fadeFraction)
        switch options.normalization {
        case .peak: h = Processing.normalizedPeak(h, dBFS: -0.1)
        case .rms: h = Processing.normalizedRMS(h, dBFS: -24)
        case .none: break
        }
        return h
    }

    public static func render(_ master: [Double], masterRate: Double, preset: ExportPreset, options: ExportOptions) -> [Double] {
        render(master, masterRate: masterRate, sampleRate: preset.sampleRate, length: preset.length, options: options)
    }

    /// Safe file name from free text.
    public static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? "IR" : cleaned
    }
}
