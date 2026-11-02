import Testing
@testable import MysticCore

@Suite("Input latency probe")
struct LatencyProbeTests {
    @Test("the first frame received after the nudge gives the time to its showing")
    func answer() {
        let probe=LatencyProbe()
        probe.arm(now:1_000)
        probe.frameRendered(receive:500,render:1_200)
        #expect(probe.answer == nil)
        probe.frameRendered(receive:1_100,render:1_400)
        probe.frameRendered(receive:1_200,render:1_900)
        #expect(probe.answer == 400)
    }
    @Test("a frame is ignored when nothing is armed or it shows before it arrived")
    func ignored() {
        let probe=LatencyProbe()
        probe.frameRendered(receive:1_100,render:1_400)
        #expect(probe.answer == nil)
        probe.arm(now:1_000)
        probe.frameRendered(receive:1_100,render:1_050)
        #expect(probe.answer == nil)
        probe.frameRendered(receive:1_100,render:1_400)
        probe.disarm()
        #expect(probe.answer == nil)
        #expect(!probe.armed)
    }
    @Test("the screen must have been still for 150 ms")
    func idle() {
        let probe=LatencyProbe()
        probe.frameReceived(1_000_000)
        probe.frameReceived(900_000)
        #expect(!probe.isIdle(now:1_149_999))
        #expect(probe.isIdle(now:1_150_000))
    }
    @Test("the summary is Nightjar's best, median and slowest tenth")
    func summary() {
        #expect(LatencyProbe.summarize([]) == nil)
        let samples: [Int64]=[15,1,14,2,13,3,12,4,11,5,10,6,9,7,8]
        #expect(LatencyProbe.summarize(samples) == .init(bestMicros:1,typicalMicros:8,slowestMicros:14))
        #expect(LatencyProbe.summarize([7]) == .init(bestMicros:7,typicalMicros:7,slowestMicros:7))
    }
}
