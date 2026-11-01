import Foundation
import XCTest
import MysticCore
import MysticKit
@testable import MysticDesktop

@MainActor
final class DiagnosticsTests: XCTestCase {
    private let measured=OverlayMeasures(renderedFps:119.94,receivedFps:120,videoMbps:48.24,lossPercent:0.12,networkMs:7.6,
                                         varianceMs:1.2,hostMs:3.24,decodeMs:1.234,renderMs:0.5)
    /// Nightjar's `stream/overlay.rs` tests.
    func testCompactShowsWhatWasMeasuredBehindTheHealthMark() {
        let line=OverlayText.compact(measured)
        XCTAssertEqual(line.health,.good);XCTAssertEqual(line.text,"119.9 FPS · 8 ms RTT · 0.1% loss")
        XCTAssertEqual(OverlayText.compact(OverlayMeasures()).health,.unknown)
        XCTAssertEqual(OverlayText.compact(OverlayMeasures()).text,"")
        let early=OverlayText.compact(OverlayMeasures(networkMs:45))
        XCTAssertEqual(early.health,.fair);XCTAssertEqual(early.text,"45 ms RTT")
        var lossy=measured;lossy.lossPercent=6
        XCTAssertEqual(OverlayText.compact(lossy).health,.poor)
        XCTAssertEqual([OverlayHealth.unknown,.good,.fair,.poor].map(\.glyph),["●","●","▲","✕"])
    }
    func testStatisticsAreAndroidsSixLines() {
        XCTAssertEqual(OverlayText.statistics(stream:"1920x1080 120 fps",measured).map(\.1),[
            "1920x1080 120 fps","119.9 rendered · 120.0 received FPS","48.2 Mbps payload · 0.12% loss",
            "8 ms RTT (±1 ms)","3.2 ms","1.23 ms decode · 0.50 ms render"])
        XCTAssertEqual(OverlayText.statistics(stream:"s",OverlayMeasures())[3].1,"— ms RTT (±— ms)")
    }
    func testHardwareLinesFollowAndroidInBothModes() throws {
        let sample=try JSONDecoder().decode(HostHardware.self,from:Data(#"{"available":true,"sampledAtUnixMs":1791712800000,"intervalMs":1000,"cpu":{"cpu_usage_percent":41.6},"gpus":[{"id":0,"name":"","metrics":{"gpu_usage_percent":0,"gpu_temperature_c":61.5,"gpu_clock_mhz":2400}}]}"#.utf8))
        let statistics=OverlayText.hardware(sample,debug:false)
        XCTAssertEqual(statistics.map(\.0),["Host CPU","Host GPU 0"])
        XCTAssertEqual(statistics.map(\.1),["41.6%","0.0% · 61.5 °C · — W"])
        let debug=OverlayText.hardware(sample,debug:true)
        XCTAssertEqual(debug[1].1,"1791712800000 ms since Unix epoch · Interval: 1000 ms")
        XCTAssertEqual(debug[2].1,"Unnamed GPU")
        XCTAssertEqual(debug[3].1,"0.0% · GPU clock: 2400 MHz · Memory clock: — MHz")
        XCTAssertEqual(debug.count,8)
    }
    func testTheSessionLogIsRedactedStampedAndKeepsTheLastRun() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("mystic-log-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let fixed=Date(timeIntervalSince1970:1_793_000_000.123)
        let first=SessionLog(folder:folder,now:{ fixed })
        SessionLog.addSecrets(["Gaming Rig",nil,"10.0.0.42"])
        first.write("Connecting to Gaming Rig at 10.0.0.42.")
        first.write("two\nlines")
        first.flush()
        let text=try String(contentsOf:first.file,encoding:.utf8)
        XCTAssertFalse(text.contains("Gaming Rig") || text.contains("10.0.0.42"),text)
        XCTAssertTrue(text.hasPrefix("2026-10-26T"),text)
        XCTAssertEqual(text.split(separator:"\n").count,3,"each line stamped")
        // The next launch keeps this run as the previous one.
        let second=SessionLog(folder:folder);second.write("next run");second.flush()
        XCTAssertEqual(try String(contentsOf:folder.appendingPathComponent(SessionLog.previous),encoding:.utf8),text)
        XCTAssertTrue(try String(contentsOf:second.file,encoding:.utf8).hasSuffix(" next run\n"))
        let attributes=try FileManager.default.attributesOfItem(atPath:second.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600,"only this user reads it")
    }
    func testRemoteCheckResultsReadAsNightjarSaysThem() throws {
        func report(_ json: String) throws -> RemoteCheckReport { RemoteCheckReport(try JSONDecoder().decode(RemoteCheckResult.self,from:Data(json.utf8))) }
        let direct=try report(#"{"outcome":"verified","path":"direct","error":null,"stats":{"latencyMs":12.5,"jitterMs":1.5,"lossPercent":0}}"#)
        XCTAssertTrue(direct.verified);XCTAssertEqual(direct.path,"Direct");XCTAssertEqual(direct.latencyMs,12.5)
        XCTAssertEqual(try report(#"{"outcome":"verified","path":"relay"}"#).path,"Relay (DERP)")
        XCTAssertEqual(try report(#"{"outcome":"verified","path":"unknown"}"#).path,"Unavailable")
        let gone=try report(#"{"outcome":"unreachable","path":"","error":"timed out"}"#)
        XCTAssertFalse(gone.verified);XCTAssertEqual(gone.summary,RemoteCheckReport.failed);XCTAssertEqual(gone.error,"timed out")
        XCTAssertTrue(try report(#"{"outcome":"pairRevoked","path":""}"#).summary.contains("no longer paired"))
        XCTAssertTrue(try report(#"{"outcome":"notPaired","error":"not paired"}"#).summary.hasPrefix("Pair this PC locally first"))
    }
    func testTheHardwarePollAsksOnceAtATime() {
        let poll=HardwarePoll()
        XCTAssertNil(poll.due(nowMillis:0,wanted:false))
        let first=try? XCTUnwrap(poll.due(nowMillis:1000,wanted:true))
        XCTAssertNil(poll.due(nowMillis:1500,wanted:true))
        XCTAssertTrue(poll.answered(generation:first ?? 0,nowMillis:1200,.sample(sampledAtUnixMs:1,intervalMs:1000)))
        XCTAssertTrue(poll.fresh(nowMillis:6100));XCTAssertFalse(poll.fresh(nowMillis:6200))
    }
}
