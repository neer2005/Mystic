import XCTest
@testable import MysticStream

final class HDRToneMapTests: XCTestCase {
    func testPQCodesMatchST2084() {
        XCTAssertEqual(HDRToneMap.pq(nits:0),0,accuracy:1e-6)
        XCTAssertEqual(HDRToneMap.pq(nits:100),0.5081,accuracy:1e-3)
        XCTAssertEqual(HDRToneMap.pq(nits:1000),0.7518,accuracy:1e-3)
        XCTAssertEqual(HDRToneMap.pq(nits:10000),1,accuracy:1e-6)
    }
    func testAScreenThatShowsTheSourcesPeakLeavesThePictureAlone() {
        let roomy=HDRToneMap(sourceNits:1000,headroom:16)
        XCTAssertFalse(roomy.active)
        XCTAssertEqual(roomy.map(0.7),0.7)
        XCTAssertFalse(HDRToneMap(sourceNits:1000,headroom:10).active,"1,000 nits at a headroom of 10 fits exactly")
    }
    func testHighlightsRollOffOntoTheScreensPeakAndShadowsStay() {
        let curve=HDRToneMap(sourceNits:1000,headroom:2)
        XCTAssertTrue(curve.active)
        XCTAssertEqual(curve.displayPeak,Float(HDRToneMap.pq(nits:200)),accuracy:1e-6)
        XCTAssertEqual(curve.map(curve.sourcePeak),curve.displayPeak,accuracy:1e-4,"the source's peak lands on the screen's")
        XCTAssertEqual(curve.map(0.3),0.3,accuracy:1e-6,"below the knee nothing changes")
        var previous: Float=0
        for step in 0...100 {
            let value=curve.map(Float(step)/100)
            XCTAssertGreaterThanOrEqual(value,previous-1e-6,"never darker for a brighter input")
            XCTAssertLessThanOrEqual(value,curve.displayPeak+1e-6,"never past the screen")
            previous=value
        }
    }
    func testAnSDRScreenStillGetsTheWholePictureBelowItsWhite() {
        let curve=HDRToneMap(sourceNits:4000,headroom:1)
        XCTAssertEqual(curve.displayPeak,Float(HDRToneMap.pq(nits:100)),accuracy:1e-6)
        XCTAssertEqual(curve.map(1),curve.displayPeak,accuracy:1e-4)
        XCTAssertGreaterThan(curve.map(curve.sourcePeak*0.9),curve.map(curve.sourcePeak*0.8),"highlights keep their order")
    }
    func testTheSourcesPeakComesFromItsMetadata() {
        // MaxCLL 600, MaxFALL 200.
        let light=Data([0x02,0x58,0x00,0xC8])
        // Primaries and white point, then max 4,000 nits and min 0.005 nits in 0.0001 nits.
        var mastering=Data(repeating:0,count:16)
        mastering += Data([0x02,0x62,0x5A,0x00]);mastering += Data([0x00,0x00,0x00,0x32])
        XCTAssertEqual(HDRToneMap.sourceNits(masteringDisplay:mastering,contentLightLevel:light),600,"MaxCLL is what the content reaches")
        XCTAssertEqual(HDRToneMap.sourceNits(masteringDisplay:mastering,contentLightLevel:nil),4000)
        XCTAssertEqual(HDRToneMap.sourceNits(masteringDisplay:mastering,contentLightLevel:Data([0,0,0,0])),4000,"an unmeasured MaxCLL is zero")
        XCTAssertEqual(HDRToneMap.sourceNits(masteringDisplay:nil,contentLightLevel:nil),HDRToneMap.defaultSourceNits)
        XCTAssertEqual(HDRToneMap.sourceNits(masteringDisplay:Data([1,2]),contentLightLevel:Data([1])),HDRToneMap.defaultSourceNits,"short data is ignored")
    }
    func testOddInputsStayInRange() {
        for (nits,headroom) in [(Double.nan,2.0),(50,2),(20000,2),(1000,.infinity),(1000,0)] {
            let curve=HDRToneMap(sourceNits:nits,headroom:headroom)
            XCTAssertTrue((0...1).contains(curve.sourcePeak) && (0...1).contains(curve.displayPeak),"\(nits), \(headroom)")
            XCTAssertLessThanOrEqual(curve.displayPeak,curve.sourcePeak)
        }
    }
}
