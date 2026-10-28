import Foundation
import MysticCore

/// One instance per stream. Decoder and presenter use the same generation gate,
/// so completions from invalidated sessions cannot contaminate a new session.
public final class VideoTelemetry: @unchecked Sendable {
    private let lock=NSLock()
    private var generation: UInt64 = 0
    private var accumulator: VideoTelemetryAccumulator
    public init(capacity: Int = 600) { accumulator=VideoTelemetryAccumulator(capacity:capacity) }
    static func nowMicros() -> UInt64 { DispatchTime.now().uptimeNanoseconds/1_000 }
    func activate(generation: UInt64) {
        lock.lock();defer { lock.unlock() };self.generation=generation
    }
    func submit(generation: UInt64,hostTenthMs: UInt16,receiveMicros: UInt64,completeMicros: UInt64) {
        lock.lock();defer { lock.unlock() }
        guard self.generation == generation else { return }
        accumulator.submit(hostTenthMs:hostTenthMs,receiveMicros:receiveMicros,completeMicros:completeMicros)
    }
    func decode(generation: UInt64,startMicros: UInt64,endMicros: UInt64) {
        lock.lock();defer { lock.unlock() }
        guard self.generation == generation else { return }
        accumulator.decode(startMicros:startMicros,endMicros:endMicros)
    }
    func enqueue(generation: UInt64,timing: VideoFrameTiming,startMicros: UInt64,endMicros: UInt64) {
        lock.lock();defer { lock.unlock() }
        guard self.generation == generation else { return }
        accumulator.enqueue(submitMicros:timing.submitMicros,decodedMicros:timing.decodedMicros,startMicros:startMicros,endMicros:endMicros)
    }
    public func snapshot() -> VideoTelemetrySnapshot {
        lock.lock();defer { lock.unlock() };return accumulator.snapshot(nowMicros:Self.nowMicros())
    }
}
