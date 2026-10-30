import XCTest
import MysticCore
@testable import MysticStream

final class VideoTelemetryTests: XCTestCase {
    func testPresentationCountersAndRendererMetricsRejectOldGenerations() {
        let telemetry=VideoTelemetry();telemetry.activate(generation:1)
        telemetry.presentationQueue(generation:1,depth:2)
        telemetry.presentationDrop(generation:1,reason:.superseded,count:3)
        telemetry.rendererMetrics(generation:1,dropped:5,corrupted:1)
        telemetry.activate(generation:2)
        telemetry.presentationQueue(generation:1,depth:2)
        telemetry.presentationDrop(generation:1,reason:.late,count:99)
        telemetry.presentationLate(generation:1);telemetry.presentationResynchronize(generation:1)
        telemetry.rendererMetrics(generation:1,dropped:999,corrupted:999)
        let snapshot=telemetry.snapshot().presentation
        XCTAssertEqual(snapshot.queueDepth,0);XCTAssertEqual(snapshot.peakQueueDepth,2)
        XCTAssertEqual(snapshot.droppedFrames,3);XCTAssertEqual(snapshot.lateFrames,0)
        XCTAssertEqual(snapshot.resynchronizations,0);XCTAssertNil(snapshot.rendererDroppedFrames)
        telemetry.presentationQueue(generation:2,depth:1)
        telemetry.rendererMetrics(generation:2,dropped:7,corrupted:0)
        XCTAssertEqual(telemetry.snapshot().presentation.queueDepth,1)
        XCTAssertEqual(telemetry.snapshot().presentation.rendererDroppedFrames,7)
    }
    func testGenerationGateRejectsAllStaleMeasurementPaths() {
        let telemetry=VideoTelemetry()
        telemetry.activate(generation:3)
        telemetry.submit(generation:3,hostTenthMs:12,receiveMicros:100,completeMicros:200)
        telemetry.decode(generation:3,startMicros:10,endMicros:20)
        telemetry.activate(generation:4)
        telemetry.submit(generation:3,hostTenthMs:99,receiveMicros:100,completeMicros:999)
        telemetry.decode(generation:3,startMicros:10,endMicros:999)
        telemetry.enqueue(generation:3,timing:VideoFrameTiming(submitMicros:0,decodedMicros:20),startMicros:30,endMicros:40)
        let snapshot=telemetry.snapshot()
        XCTAssertEqual(snapshot.submitted,1);XCTAssertEqual(snapshot.decoded,1);XCTAssertEqual(snapshot.enqueued,0)
        XCTAssertEqual(snapshot.timings[.hostProcessing]?.p50Micros,1200)
        XCTAssertEqual(snapshot.timings[.decode]?.p50Micros,10)
        telemetry.enqueue(generation:4,timing:VideoFrameTiming(submitMicros:0,decodedMicros:20),startMicros:30,endMicros:40)
        XCTAssertEqual(telemetry.snapshot().enqueued,1)
        XCTAssertEqual(VideoTelemetry().snapshot().submitted,0)
    }
    func testConcurrentCompletionsStayBounded() {
        let telemetry=VideoTelemetry(capacity:8)
        telemetry.activate(generation:1)
        DispatchQueue.concurrentPerform(iterations:1000) { _ in
            telemetry.decode(generation:1,startMicros:100,endMicros:200)
        }
        let snapshot=telemetry.snapshot()
        XCTAssertEqual(snapshot.decoded,1000)
        XCTAssertEqual(snapshot.timings[.decode]?.count,8)
        XCTAssertEqual(snapshot.timings[.decode]?.p95Micros,100)
    }
}
