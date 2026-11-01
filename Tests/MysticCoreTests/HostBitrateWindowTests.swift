import Testing
@testable import MysticCore

/// Nightjar's `host_abr.rs` tests, for the same window.
@Suite("Host bitrate window")
struct HostBitrateWindowTests {
    @Test func reportsGoEveryThreeSecondsOneAtATime() {
        var window=HostBitrateWindow(initialKbps:35_000,streamKbps:50_000,nowMillis:1000)
        #expect(window.currentKbps == 35_000,"the host's initial bitrate")
        #expect(HostBitrateWindow(initialKbps:0,streamKbps:50_000,nowMillis:0).currentKbps == 50_000)
        for _ in 0..<3 { window.add(completed:118,dropped:2,decoded:120) }
        #expect(window.due(nowMillis:3999,rttMillis:8) == nil,"not before three seconds")
        let report=window.due(nowMillis:4000,rttMillis:8)
        #expect(report == HostBitrateFeedback(packetLoss:6.0*100/360,rttMs:8,decodeFps:120,droppedFrames:6,currentKbps:35_000))
        window.add(completed:120,dropped:0,decoded:120)
        #expect(window.due(nowMillis:8000,rttMillis:nil) == nil,"the last report is not answered yet")
        #expect(window.answered(newKbps:28_000) == 28_000)
        let next=window.due(nowMillis:8000,rttMillis:nil)
        #expect(next?.currentKbps == 28_000 && next?.droppedFrames == 0 && next?.rttMs == 0)
        #expect(window.answered(newKbps:28_000) == nil,"kept")
        #expect(window.answered(newKbps:nil) == nil,"a failed report changes nothing")
        #expect(window.currentKbps == 28_000)
    }
}
