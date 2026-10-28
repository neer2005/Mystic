import Testing
@testable import MysticCore

struct VideoTelemetryTests {
    @Test func exactUnitsAndIndependentClocks() {
        var recorder=VideoTelemetryAccumulator()
        recorder.submit(hostTenthMs:37,receiveMicros:9_000_000,completeMicros:9_002_500)
        recorder.decode(startMicros:100,endMicros:4100)
        recorder.enqueue(submitMicros:50,decodedMicros:4100,startMicros:7100,endMicros:9100)
        let snapshot=recorder.snapshot(nowMicros:10_000)
        #expect(snapshot.timings[.hostProcessing]?.p50Micros == 3700)
        #expect(snapshot.timings[.reassembly]?.p50Micros == 2500)
        #expect(snapshot.timings[.decode]?.p50Micros == 4000)
        #expect(snapshot.timings[.displayWait]?.p50Micros == 3000)
        #expect(snapshot.timings[.rendererEnqueue]?.p50Micros == 2000)
        #expect(snapshot.timings[.clientToEnqueue]?.p50Micros == 9050)
        #expect(snapshot.submitted == 1 && snapshot.decoded == 1 && snapshot.enqueued == 1)
        #expect(snapshot.decodedFPS == nil)
    }
    @Test func missingHostAndMalformedIntervalsStayUnavailable() {
        var recorder=VideoTelemetryAccumulator()
        recorder.submit(hostTenthMs:0,receiveMicros:UInt64.max,completeMicros:1)
        recorder.decode(startMicros:0,endMicros:UInt64.max)
        let snapshot=recorder.snapshot(nowMicros:0)
        #expect(snapshot.timings.isEmpty)
        #expect(VideoTelemetryAccumulator.duration(from:0,to:0) == 0)
        #expect(VideoTelemetryAccumulator.duration(from:0,to:60_000_000) == 60_000_000)
        #expect(VideoTelemetryAccumulator.duration(from:0,to:60_000_001) == nil)
    }
    @Test func rollingPercentilesAndPollRates() {
        var recorder=VideoTelemetryAccumulator(capacity:3)
        _=recorder.snapshot(nowMicros:1_000_000)
        for value in [100,200,300,400] {
            recorder.decode(startMicros:0,endMicros:UInt64(value))
        }
        let snapshot=recorder.snapshot(nowMicros:3_000_000)
        #expect(snapshot.timings[.decode]?.count == 3)
        #expect(snapshot.timings[.decode]?.p50Micros == 300)
        #expect(snapshot.timings[.decode]?.p95Micros == 400)
        #expect(snapshot.decodedFPS == 2)
        #expect(snapshot.enqueuedFPS == 0)
        let same=recorder.snapshot(nowMicros:3_000_000)
        let backwards=recorder.snapshot(nowMicros:2_000_000)
        #expect(same.decodedFPS == nil && backwards.decodedFPS == nil)
        let idle=recorder.snapshot(nowMicros:4_000_000)
        #expect(idle.decodedFPS == 0)
        var next=VideoTelemetryAccumulator()
        #expect(next.snapshot(nowMicros:5_000_000).timings.isEmpty)
    }
}
