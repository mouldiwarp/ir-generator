import Foundation

public enum WavFormat: String, Codable, CaseIterable, Sendable {
    case pcm16, pcm24, float32

    public var label: String {
        switch self {
        case .pcm16: return "16-bit"
        case .pcm24: return "24-bit"
        case .float32: return "32-bit float"
        }
    }
}

public enum WavError: Error, LocalizedError {
    case notWave, unsupported(String), truncated

    public var errorDescription: String? {
        switch self {
        case .notWave: return "Not a WAV file."
        case .unsupported(let s): return "Unsupported WAV format: \(s)."
        case .truncated: return "The WAV file is truncated."
        }
    }
}

/// Mono RIFF/WAVE writer and a general reader (PCM 8/16/24/32, float 32/64, WAVE_FORMAT_EXTENSIBLE).
public enum WavFile {
    public static func encode(_ samples: [Double], sampleRate: Int, format: WavFormat) -> Data {
        let bits: Int, tag: UInt16
        switch format {
        case .pcm16: bits = 16; tag = 1
        case .pcm24: bits = 24; tag = 1
        case .float32: bits = 32; tag = 3
        }
        let bytesPer = bits / 8
        var payload = Data(capacity: samples.count * bytesPer)
        for s in samples {
            let c = max(-1, min(1, s))
            switch format {
            case .pcm16:
                let v = Int16(clamping: Int((c * 32768).rounded()))
                payload.append(le: UInt16(bitPattern: v))
            case .pcm24:
                let v = Int32(max(-8_388_608, min(8_388_607, Int((c * 8_388_608).rounded()))))
                let u = UInt32(bitPattern: v)
                payload.append(contentsOf: [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF)])
            case .float32:
                payload.append(le: Float(s).bitPattern)   // float keeps headroom; no clamp
            }
        }
        if payload.count % 2 == 1 { payload.append(0) }

        var d = Data()
        let fmtSize: UInt32 = tag == 3 ? 18 : 16
        let factChunk: UInt32 = tag == 3 ? 12 : 0
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le: UInt32(4 + (8 + fmtSize) + factChunk + 8 + UInt32(payload.count)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(le: fmtSize)
        d.append(le: tag)
        d.append(le: UInt16(1))                                   // mono
        d.append(le: UInt32(sampleRate))
        d.append(le: UInt32(sampleRate * bytesPer))               // byte rate
        d.append(le: UInt16(bytesPer))                            // block align
        d.append(le: UInt16(bits))
        if tag == 3 {
            d.append(le: UInt16(0))                               // cbSize
            d.append(contentsOf: Array("fact".utf8))
            d.append(le: UInt32(4))
            d.append(le: UInt32(samples.count))
        }
        d.append(contentsOf: Array("data".utf8))
        d.append(le: UInt32(samples.count * bytesPer))
        d.append(payload)
        return d
    }

    public static func write(_ samples: [Double], sampleRate: Int, format: WavFormat, to url: URL) throws {
        try encode(samples, sampleRate: sampleRate, format: format).write(to: url, options: .atomic)
    }

    public struct Decoded: Sendable {
        public var samples: [Double]      // first channel
        public var sampleRate: Double
        public var channels: Int
        public var bitsPerSample: Int
        public var isFloat: Bool
    }

    public static func read(_ url: URL) throws -> Decoded { try decode(Data(contentsOf: url)) }

    public static func decode(_ data: Data) throws -> Decoded {
        let b = [UInt8](data)
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { throw WavError.notWave }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var pos = 12
        var tag = 0, channels = 0, rate = 0, bits = 0
        var dataRange: Range<Int>?
        while pos + 8 <= b.count {
            let id = String(bytes: b[pos..<pos + 4], encoding: .ascii) ?? ""
            let size = u32(pos + 4)
            let body = pos + 8
            if id == "fmt " {
                guard body + 16 <= b.count else { throw WavError.truncated }
                tag = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if tag == 0xFFFE, size >= 40, body + 26 <= b.count { tag = u16(body + 24) }   // SubFormat GUID
            } else if id == "data" {
                dataRange = body..<min(b.count, body + size)
            }
            pos = body + size + (size & 1)
        }
        guard let range = dataRange, channels > 0, rate > 0 else { throw WavError.truncated }
        let isFloat = tag == 3
        guard tag == 1 || tag == 3 else { throw WavError.unsupported("format tag \(tag)") }
        guard (!isFloat && [8, 16, 24, 32].contains(bits)) || (isFloat && [32, 64].contains(bits)) else {
            throw WavError.unsupported("\(bits)-bit \(isFloat ? "float" : "PCM")")
        }
        let bytesPer = bits / 8, frame = bytesPer * channels
        let frames = range.count / frame
        var out = [Double](repeating: 0, count: frames)
        for i in 0..<frames {
            let o = range.lowerBound + i * frame
            switch (isFloat, bits) {
            case (false, 8): out[i] = (Double(b[o]) - 128) / 128
            case (false, 16): out[i] = Double(Int16(bitPattern: UInt16(u16(o)))) / 32768
            case (false, 24):
                let v = Int32(bitPattern: UInt32(b[o]) << 8 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 24) >> 8
                out[i] = Double(v) / 8_388_608
            case (false, 32): out[i] = Double(Int32(bitPattern: UInt32(u32(o)))) / 2_147_483_648
            case (true, 32): out[i] = Double(Float(bitPattern: UInt32(u32(o))))
            default:
                var u: UInt64 = 0
                for k in 0..<8 { u |= UInt64(b[o + k]) << (8 * UInt64(k)) }
                out[i] = Double(bitPattern: u)
            }
        }
        return Decoded(samples: out, sampleRate: Double(rate), channels: channels, bitsPerSample: bits, isFloat: isFloat)
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
