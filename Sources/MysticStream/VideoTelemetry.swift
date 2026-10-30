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
        lock.lock();defer { lock.unlock() };self.generation=generation;accumulator.presentationQueue(depth:0);accumulator.rendererMetrics(dropped:nil,corrupted:nil)
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
    func presentationDrop(generation: UInt64,reason: PresentationDropReason,count: UInt64 = 1) {
        lock.lock();defer { lock.unlock() };guard self.generation == generation else { return }
        accumulator.presentationDrop(reason,count:count)
    }
    func presentationQueue(generation: UInt64,depth: Int) {
        lock.lock();defer { lock.unlock() };guard self.generation == generation else { return }
        accumulator.presentationQueue(depth:depth)
    }
    func presentationLate(generation: UInt64) {
        lock.lock();defer { lock.unlock() };guard self.generation == generation else { return }
        accumulator.presentationLate()
    }
    func presentationResynchronize(generation: UInt64) {
        lock.lock();defer { lock.unlock() };guard self.generation == generation else { return }
        accumulator.presentationResynchronize()
    }
    func rendererMetrics(generation: UInt64,dropped: UInt64?,corrupted: UInt64?) {
        lock.lock();defer { lock.unlock() };guard self.generation == generation else { return }
        accumulator.rendererMetrics(dropped:dropped,corrupted:corrupted)
    }
    public func snapshot() -> VideoTelemetrySnapshot {
        lock.lock();defer { lock.unlock() };return accumulator.snapshot(nowMicros:Self.nowMicros())
    }
}
