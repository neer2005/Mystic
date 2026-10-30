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
                try await wait { receiver.accepted.count == 1 }
                let sample=try XCTUnwrap(receiver.accepted.first)
                let interval=(1_000_000+Int64(fps)/2)/Int64(fps)
                XCTAssertEqual(sample.ptsMicros,mode == .balanced ? interval : 0)
                XCTAssertEqual(CMTimeCompare(sample.duration,CMTime(value:1,timescale:Int32(fps))),0)
                XCTAssertEqual(presenter.videoSize.width,64)
                presenter.reset(generation:2)
            }
        }
    }
    func testBackpressureRetainsOnlyInFlightAndLatestImagesAndCountsSupersededFrames() async throws {
        let receiver=TestPresentationReceiver();receiver.hold=true
        let clock=PresentationClock(),telemetry=VideoTelemetry();telemetry.activate(generation:1)
        let presenter=DisplayLayerPresenter(telemetry:telemetry,mode:.lowLatency,receiverOverride:receiver,rendererClock:{ clock.now })
        presenter.reset(generation:1);presenter.offer(try frame(pts:0,generation:1))
        try await wait { receiver.waiting }
        let middle=try pixel(width:65),last=try pixel(width:80)
        for n in 1...100 {
            presenter.offer(DecodedVideoFrame(pixelBuffer:n == 100 ? last : middle,presentationTime:CMTime(value:Int64(n*10),timescale:1_000_000),generation:1))
        }
        let pressure=telemetry.snapshot().presentation
        XCTAssertEqual(pressure.queueDepth,2);XCTAssertEqual(pressure.peakQueueDepth,2)
        XCTAssertEqual(pressure.drops[.superseded],99)
        receiver.release()
        try await wait { receiver.accepted.count == 2 && telemetry.snapshot().presentation.queueDepth == 0 }
        XCTAssertEqual(receiver.accepted.map(\.width),[64,80])
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
        XCTAssertEqual(telemetry.snapshot().presentation.drops[.reset],1)
        presenter.reset(generation:3)
    }
    func testRateChangeFlushesOldSchedulingAndUsesNewBufferDuration() async throws {
        let receiver=TestPresentationReceiver(),clock=PresentationClock(),telemetry=VideoTelemetry()
        telemetry.activate(generation:1)
        let presenter=DisplayLayerPresenter(telemetry:telemetry,mode:.balanced,receiverOverride:receiver,rendererClock:{ clock.now })
        presenter.reset(generation:1);presenter.offer(try frame(pts:0,generation:1))
        try await wait { receiver.accepted.count == 1 }
        clock.time=16667
        presenter.offer(try frame(pts:16667,generation:1,fps:120))
        try await wait { receiver.accepted.count == 2 }
        XCTAssertEqual(receiver.accepted.last?.ptsMicros,25000)
        XCTAssertEqual(receiver.preservedFlushes,1)
        XCTAssertEqual(telemetry.snapshot().presentation.resynchronizations,1)
        presenter.reset(generation:2)
    }
    func testMalformedAndOutOfOrderTimestampsCannotPoisonFollowingFrames() async throws {
        let receiver=TestPresentationReceiver(),clock=PresentationClock(),telemetry=VideoTelemetry(),failures=PresentationFailures()
        telemetry.activate(generation:1)
        let presenter=DisplayLayerPresenter(telemetry:telemetry,mode:.lowLatency,receiverOverride:receiver,rendererClock:{ clock.now },onFailure:{ failures.add($0) })
        presenter.reset(generation:1);presenter.offer(try frame(pts:0,generation:1))
        try await wait { receiver.accepted.count == 1 }
        presenter.offer(try frame(pts:Int64.max,generation:1))
        try await wait { telemetry.snapshot().presentation.drops[.invalidTimestamp] == 1 }
        clock.time=1000;presenter.offer(try frame(pts:1000,generation:1))
        try await wait { receiver.accepted.count == 2 }
        presenter.offer(try frame(pts:1000,generation:1))
        try await wait { telemetry.snapshot().presentation.drops[.outOfOrder] == 1 }
        clock.time=2000;presenter.offer(try frame(pts:1_000_000,generation:1))
        try await wait { telemetry.snapshot().presentation.drops[.invalidTimestamp] == 2 }
        clock.time=3000;presenter.offer(try frame(pts:1_016_667,generation:1))
        try await wait { failures.values.count == 1 }
        XCTAssertEqual(receiver.accepted.count,2)
        XCTAssertEqual(telemetry.snapshot().presentation.drops[.invalidTimestamp],3)
        presenter.reset(generation:2)
    }
    func testResetCancelsAnEarlyFrameWaitWithoutReportingAPlaybackFailure() async throws {
        let receiver=TestPresentationReceiver(),clock=PresentationClock(),failures=PresentationFailures()
        let presenter=DisplayLayerPresenter(telemetry:nil,mode:.balanced,receiverOverride:receiver,rendererClock:{ clock.now },onFailure:{ failures.add($0) })
        presenter.reset(generation:1);presenter.offer(try frame(pts:0,generation:1))
        try await wait { receiver.accepted.count == 1 }
        presenter.offer(try frame(pts:83333,generation:1))
        try await wait { presenter.isWaitingForPresentation }
        presenter.reset(generation:2)
        presenter.offer(try frame(pts:0,generation:2,fps:120))
        try await wait { receiver.accepted.count == 2 }
        XCTAssertEqual(receiver.accepted.last?.ptsMicros,8333)
        XCTAssertTrue(failures.values.isEmpty)
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
@MainActor
private final class TestPresentationReceiver: PresentationReceiver {
    struct Sample { let ptsMicros:Int64;let duration:CMTime;let width:Int }
    var accepted:[Sample]=[]
    var hold=false
    private var pending:CheckedContinuation<AVSampleBufferVideoRenderer.Receiver.EnqueueResult,Never>?
    private(set) var flushes=0,preservedFlushes=0
    var waiting:Bool { pending != nil }
    func enqueue(_ sample:sending CMSampleBuffer) async throws -> AVSampleBufferVideoRenderer.Receiver.EnqueueResult {
        let record=Sample(ptsMicros:CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),timescale:1_000_000,method:.default).value,
                          duration:CMSampleBufferGetDuration(sample),width:CMSampleBufferGetImageBuffer(sample).map(CVPixelBufferGetWidth) ?? 0)
        let result:AVSampleBufferVideoRenderer.Receiver.EnqueueResult
        if hold { result=await withCheckedContinuation { pending=$0 } } else { result = .enqueued }
        if case .enqueued = result { accepted.append(record) }
        return result
    }
    func release() { hold=false;let continuation=pending;pending=nil;continuation?.resume(returning:.enqueued) }
    func flush() { flushes+=1;let continuation=pending;pending=nil;continuation?.resume(returning:.cancelledDueToFlush) }
    func flush(removingDisplayedImage:Bool) async { if !removingDisplayedImage { preservedFlushes+=1 };flush() }
}
private final class PresentationFailures: @unchecked Sendable {
    private let lock=NSLock();private var messages:[String]=[]
    var values:[String] { lock.withLock { messages } }
    func add(_ message:String) { lock.withLock { messages.append(message) } }
}
