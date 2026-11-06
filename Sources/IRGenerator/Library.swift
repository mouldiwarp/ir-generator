import Foundation
import IRCore

/// One captured or imported IR, as listed in the library.
struct CaptureMeta: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var notes = ""
    var date = Date()
    var sampleRate: Double
    /// nil for an imported WAV.
    var settings: MeasurementSettings?
    var route: String?
    var levelDB: Double?
    var delaySamples: Int?
    var peakToNoiseDB: Double?
    var inputPeakDB: Double?
    var clipped = false
    var importedFrom: String?
    var hasRecording = false

    var isImported: Bool { importedFrom != nil }
}

/// In-memory audio for a capture.
struct CaptureAudio {
    var ir: [Double]
    var recording: [Double]?
}

/// Captures on disk: ~/Library/Application Support/IR Generator/Captures/<uuid>/{meta.json, ir.wav, recording.wav}
enum Library {
    static var root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("IR Generator/Captures", isDirectory: true)
    }()

    static func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func loadAll() -> [CaptureMeta] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")) else { return nil }
            return try? dec.decode(CaptureMeta.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    static func save(_ meta: CaptureMeta, audio: CaptureAudio?) throws {
        let dir = folder(meta.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try saveMeta(meta)
        if let a = audio {
            try WavFile.write(a.ir, sampleRate: Int(meta.sampleRate), format: .float32, to: dir.appendingPathComponent("ir.wav"))
            if let r = a.recording {
                try WavFile.write(r, sampleRate: Int(meta.sampleRate), format: .float32,
                                  to: dir.appendingPathComponent("recording.wav"))
            }
        }
    }

    static func saveMeta(_ meta: CaptureMeta) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: folder(meta.id).appendingPathComponent("meta.json"), options: .atomic)
    }

    static func loadAudio(_ meta: CaptureMeta) -> CaptureAudio? {
        let dir = folder(meta.id)
        guard let ir = try? WavFile.read(dir.appendingPathComponent("ir.wav")) else { return nil }
        let rec = meta.hasRecording ? (try? WavFile.read(dir.appendingPathComponent("recording.wav")))?.samples : nil
        return CaptureAudio(ir: ir.samples, recording: rec)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }
}
