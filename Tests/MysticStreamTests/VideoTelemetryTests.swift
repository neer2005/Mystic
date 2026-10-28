import XCTest
import MysticCore
@testable import MysticStream

final class VideoTelemetryTests: XCTestCase {
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
