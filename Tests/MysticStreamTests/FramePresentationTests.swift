import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import MysticCore
@testable import MysticStream

@MainActor
final class FramePresentationTests: XCTestCase {
    func testModesRetimeNativeSamplesAndCarryTheNegotiatedFrameDuration() async throws {
        for fps:UInt32 in [60,120] {
            for mode in FramePacingMode.allCases {
                let receiver=TestPresentationReceiver(),clock=PresentationClock()
                let presenter=DisplayLayerPresenter(telemetry:nil,mode:mode,receiverOverride:receiver,rendererClock:{ clock.now })
                presenter.reset(generation:1)
                presenter.offer(try frame(pts:9_000_000,generation:1,fps:fps))
                // The size reaches the main actor from the presentation queue.
                try await wait { receiver.accepted.count == 1 && presenter.videoSize.width == 64 }
                let sample=try XCTUnwrap(receiver.accepted.first)
                XCTAssertEqual(sample.ptsMicros,0,"Shown at the renderer's now, when the pacer says it is due")
                XCTAssertEqual(CMTimeCompare(sample.duration,CMTime(value:1,timescale:Int32(fps))),0)
                XCTAssertEqual(presenter.videoSize.width,64)
                presenter.reset(generation:2)
            }
        }
    }
    func testOnlyTheNewestWaitsWhileAPictureIsBeingPresented() async throws {
        let receiver=TestPresentationReceiver();receiver.hold=true
        let clock=PresentationClock(),telemetry=VideoTelemetry();telemetry.activate(generation:1)
        let presenter=DisplayLayerPresenter(telemetry:telemetry,mode:.lowLatency,receiverOverride:receiver,rendererClock:{ clock.now })
        presenter.reset(generation:1);presenter.offer(try frame(pts:0,generation:1))
        try await wait { receiver.waiting }
        let middle=try pixel(width:65),last=try pixel(width:80)
        for n in 1...100 {
            presenter.offer(DecodedVideoFrame(pixelBuffer:n == 100 ? last : middle,presentationTime:CMTime(value:Int64(n*10),timescale:1_000_000),generation:1))
        }
        receiver.release()
        try await wait { receiver.accepted.count == 2 && telemetry.snapshot().presentation.queueDepth == 0 }
        XCTAssertEqual(receiver.accepted.map(\.width),[64,80])
        XCTAssertEqual(telemetry.snapshot().presentation.drops[.superseded],99)
        presenter.reset(generation:2)
    }
    func testSmoothestPresentsEachWaitingPictureInTurn() async throws {
        let receiver=TestPresentationReceiver();receiver.hold=true
        let clock=PresentationClock(),telemetry=VideoTelemetry();telemetry.activate(generation:1)
        let presenter=DisplayLayerPresenter(telemetry:telemetry,mode:.smoothest,receiverOverride:receiver,rendererClock:{ clock.now })
        presenter.reset(generation:1);presenter.offer(try frame(pts:0,generation:1))
        try await wait { receiver.waiting }
        presenter.offer(DecodedVideoFrame(pixelBuffer:try pixel(width:65),presentationTime:CMTime(value:1000,timescale:1_000_000),generation:1))
        presenter.offer(DecodedVideoFrame(pixelBuffer:try pixel(width:66),presentationTime:CMTime(value:2000,timescale:1_000_000),generation:1))
        receiver.release()
        try await wait { receiver.accepted.count == 3 }
        XCTAssertEqual(receiver.accepted.map(\.width),[64,65,66])
        presenter.reset(generation:2)
    }
    func testAPictureWithoutATimestampIsDroppedAndTheNextShows() async throws {
        let receiver=TestPresentationReceiver(),clock=PresentationClock(),telemetry=VideoTelemetry()
        telemetry.activate(generation:1)
        let presenter=DisplayLayerPresenter(telemetry:telemetry,mode:.lowLatency,receiverOverride:receiver,rendererClock:{ clock.now })
        presenter.reset(generation:1);presenter.offer(try frame(pts:0,generation:1))
        try await wait { receiver.accepted.count == 1 }
        presenter.offer(try frame(pts:0,generation:1))
        try await wait { telemetry.snapshot().presentation.drops[.outOfOrder] == 1 || receiver.accepted.count == 2 }
        presenter.offer(try frame(pts:1000,generation:1))
        try await wait { receiver.accepted.count >= 2 }
        presenter.reset(generation:2)
    }
    func testResetCancelsSuspendedEnqueueAndRejectsOldGenerationWork() async throws {
        let receiver=TestPresentationReceiver();receiver.hold=true
        let clock=PresentationClock(),telemetry=VideoTelemetry(),failures=PresentationFailures()
        telemetry.activate(generation:1)
        let presenter=DisplayLayerPresenter(telemetry:telemetry,mode:.lowLatency,receiverOverride:receiver,rendererClock:{ clock.now },onFailure:{ failures.add($0) })
        presenter.reset(generation:1);presenter.offer(try frame(pts:0,generation:1))
        try await wait { receiver.waiting }
        telemetry.activate(generation:2);presenter.reset(generation:2)
        try await wait { !receiver.waiting && receiver.flushes >= 3 }
        receiver.hold=false
        presenter.offer(try frame(pts:0,generation:2,fps:120))
        try await wait { receiver.accepted.count == 1 && telemetry.snapshot().presentation.queueDepth == 0 }
        presenter.offer(try frame(pts:1,generation:1))
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertEqual(receiver.accepted.count,1);XCTAssertTrue(failures.values.isEmpty)
                presenter.reset(generation:3)
    }
    private func frame(pts:Int64,generation:UInt64,fps:UInt32 = 60) throws -> DecodedVideoFrame {
        DecodedVideoFrame(pixelBuffer:try pixel(width:64),presentationTime:CMTime(value:pts,timescale:1_000_000),generation:generation,frameRate:fps)
    }
    private func pixel(width:Int) throws -> CVPixelBuffer {
        var image:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,width,64,kCVPixelFormatType_32BGRA,nil,&image),0)
        return try XCTUnwrap(image)
    }
    private func wait(_ done:()->Bool) async throws {
        for _ in 0..<400 { if done() { return };try await Task.sleep(for:.milliseconds(2)) }
        XCTFail("Timed out waiting for presenter state")
    }
}

@MainActor
private final class PresentationClock {
    var time:Int64=0
    var now:CMTime { CMTime(value:time,timescale:1_000_000) }
}
/// Called on the presentation queue and read by the tests on the main actor.
private final class TestPresentationReceiver: PresentationReceiver, @unchecked Sendable {
    struct Sample { let ptsMicros:Int64;let duration:CMTime;let width:Int }
    private let lock=NSLock()
    // Guarded by the lock, not by the actor: the tests read them from the main actor.
    private nonisolated(unsafe) var samples:[Sample]=[],holding=false,flushCount=0
    private nonisolated(unsafe) var pending:CheckedContinuation<AVSampleBufferVideoRenderer.Receiver.EnqueueResult,Never>?
    nonisolated var accepted:[Sample] { lock.withLock { samples } }
    nonisolated var hold:Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding=newValue } }
    }
    nonisolated var flushes:Int { lock.withLock { flushCount } }
    nonisolated var waiting:Bool { lock.withLock { pending != nil } }
    func enqueue(_ sample:sending CMSampleBuffer) async throws -> AVSampleBufferVideoRenderer.Receiver.EnqueueResult {
        let record=Sample(ptsMicros:CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),timescale:1_000_000,method:.default).value,
                          duration:CMSampleBufferGetDuration(sample),width:CMSampleBufferGetImageBuffer(sample).map(CVPixelBufferGetWidth) ?? 0)
        let result:AVSampleBufferVideoRenderer.Receiver.EnqueueResult
        if hold { result=await withCheckedContinuation { continuation in lock.withLock { pending=continuation } } } else { result = .enqueued }
        if case .enqueued = result { lock.withLock { samples.append(record) } }
        return result
    }
    private nonisolated func resume(_ result:AVSampleBufferVideoRenderer.Receiver.EnqueueResult) {
        let continuation=lock.withLock { let waiting=pending;pending=nil;return waiting }
        continuation?.resume(returning:result)
    }
    nonisolated func release() { hold=false;resume(.enqueued) }
    func flush() { lock.withLock { flushCount+=1 };resume(.cancelledDueToFlush) }
    func flush(removingDisplayedImage:Bool) async { flush() }
}
private final class PresentationFailures: @unchecked Sendable {
    private let lock=NSLock();private var messages:[String]=[]
    var values:[String] { lock.withLock { messages } }
    func add(_ message:String) { lock.withLock { messages.append(message) } }
}
