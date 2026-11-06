import CIRAudio
import CoreAudio
import Foundation

/// Owns the C duplex engine and its buffers. Main-thread only.
final class CaptureEngine {
    struct Status {
        var done: Bool
        var aborted: Bool
        var recorded: Int
        var inPeak: Float
        var outPeak: Float
    }

    enum EngineError: LocalizedError {
        case start(OSStatus), noChannel(String)
        var errorDescription: String? {
            switch self {
            case .start(let s): return "The audio device would not start (Core Audio error \(s))."
            case .noChannel(let s): return s
            }
        }
    }

    private var handle: OpaquePointer?
    private var device: AudioObjectID = 0
    private var play: UnsafeMutablePointer<Float>?
    private var playCount = 0
    private var rec: UnsafeMutablePointer<Float>?
    private var recCount = 0
    private(set) var isRunning = false

    deinit { release() }

    /// Starts playing `signal` (peak 1.0) on the channels in `outMask`, recording `recordFrames` of `inChannel`
    /// (nil = meter only). `loop` repeats the signal until stopped.
    func start(device dev: AudioDevice, signal: [Double], loop: Bool, outChannels: [Int], inChannel: Int,
               recordFrames: Int?, gain: Float) throws {
        stop()
        if let bad = outChannels.first(where: { $0 >= dev.outputChannels }) {
            throw EngineError.noChannel("\(dev.name) has no output \(bad + 1).")
        }
        if inChannel >= dev.inputChannels { throw EngineError.noChannel("\(dev.name) has no input \(inChannel + 1).") }
        if handle == nil || device != dev.id {
            if let h = handle { ird_destroy(h) }
            handle = ird_create(dev.id)
            device = dev.id
        }
        play = .allocate(capacity: max(1, signal.count))
        playCount = signal.count
        for i in 0..<signal.count { play![i] = Float(signal[i]) }
        if let n = recordFrames {
            rec = .allocate(capacity: max(1, n))
            rec!.initialize(repeating: 0, count: max(1, n))
            recCount = n
        }
        let mask = outChannels.reduce(UInt64(0)) { $0 | (1 << UInt64($1)) }
        let st = ird_start(handle, play, Int64(playCount), loop, mask, rec, Int64(recCount), Int32(inChannel), gain)
        guard st == noErr else { freeBuffers(); throw EngineError.start(st) }
        isRunning = true
    }

    func setGain(_ g: Float) { if let h = handle { ird_set_gain(h, g) } }

    /// Fades out and ends the current run (the next `status()` reports done + aborted).
    func requestStop() { if let h = handle, isRunning { ird_request_stop(h) } }

    func status() -> Status {
        guard let h = handle, isRunning else { return Status(done: true, aborted: false, recorded: 0, inPeak: 0, outPeak: 0) }
        return Status(done: ird_is_done(h), aborted: ird_was_aborted(h), recorded: Int(ird_rec_position(h)),
                      inPeak: ird_take_in_peak(h), outPeak: ird_take_out_peak(h))
    }

    /// Stops the device and returns the recording, if there was one.
    @discardableResult
    func stop() -> [Double]? {
        guard let h = handle, isRunning else { return nil }
        ird_stop(h)
        isRunning = false
        var out: [Double]?
        if let r = rec {
            let n = min(recCount, Int(ird_rec_position(h)))
            out = (0..<recCount).map { $0 < n ? Double(r[$0]) : 0 }
        }
        freeBuffers()
        return out
    }

    private func freeBuffers() {
        play?.deallocate(); play = nil; playCount = 0
        rec?.deallocate(); rec = nil; recCount = 0
    }

    private func release() {
        stop()
        if let h = handle { ird_destroy(h) }
        handle = nil
    }
}
