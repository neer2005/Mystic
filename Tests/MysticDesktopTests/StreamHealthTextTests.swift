import XCTest
import MysticKit
@testable import MysticDesktop

final class StreamHealthTextTests: XCTestCase {
    private func report(_ findings: [String],samples: Int = 5,recent: Bool = true,period: UInt64 = 0) throws -> StreamHealthReport {
        let names="["+findings.map { "\""+$0+"\"" }.joined(separator:",")+"]"
        let json=#"{"findings":\#(names),"samples":\#(samples),"recent":\#(recent),"worstLossPercent":6.25,"worstDecodeMs":-1,"worstHostP95Ms":3,"worstDisplayP95Ms":-1,"stalls":4,"stallPeriodMs":\#(period),"hostIncludesSend":true,"lateSamples":2,"offer":"none"}"#
        return try JSONDecoder().decode(StreamHealthReport.self,from:Data(json.utf8))
    }
    func testTooLittleVideoAndNoFindingsSayWhatTheyCannotProve() throws {
        XCTAssertTrue(StreamHealthText.body(try report([],samples:2))[1].hasPrefix("Not enough recent video"))
        XCTAssertTrue(StreamHealthText.body(try report([],recent:false))[1].hasPrefix("Not enough recent video"))
        XCTAssertTrue(StreamHealthText.body(try report([]))[1].hasPrefix("No repeated bottleneck"))
    }
    func testFindingsEvidenceAndRhythmAreWorded() throws {
        let value=try report(["NETWORK","PERIODIC"],period:125_000)
        let body=StreamHealthText.body(value)
        XCTAssertEqual(body.count,3)
        XCTAssertTrue(body[1].hasPrefix("Network:"))
        XCTAssertTrue(body[2].contains("4 network stalls") && body[2].contains("about every 2 min"))
        let evidence=StreamHealthText.evidence(value)
        XCTAssertEqual(evidence[0].1,"6.2 %")
        XCTAssertEqual(evidence[1].1,"no data yet")
        XCTAssertEqual(evidence[2].0,"Host to network p95")
        XCTAssertTrue(StreamHealthText.copy(value).contains("Frame loss: 6.2 %"))
    }
    func testRhythmPeriods() {
        XCTAssertEqual(StreamHealthText.period(45_000),"45 s")
        XCTAssertEqual(StreamHealthText.period(150_000),"2.5 min")
        XCTAssertEqual(StreamHealthText.period(600_000),"10 min")
    }
    func testThermalStatesMapToTheDoctorsLevels() {
        XCTAssertEqual(StreamHealthModel.thermalLevel(.nominal),0)
        XCTAssertEqual(StreamHealthModel.thermalLevel(.fair),1)
        XCTAssertEqual(StreamHealthModel.thermalLevel(.critical),3)
    }
}
