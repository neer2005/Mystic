import XCTest
@testable import MysticKit

final class HostGraphicsTests: XCTestCase {
    func testHostTypesRangesChoicesAndUnknownStates() throws {
        let panel=try JSONDecoder().decode(HostGraphics.self,from:Data(#"""
        {"revision":7,"state":"configurable","host_control":true,"writable_now":true,"gpus":[{"id":1,"name":"Radeon","driver":"test","settings":[
        {"id":"anti_lag.enabled","group":"anti_lag","kind":"toggle","state":"configurable","value":true},
        {"id":"chill.max_fps","group":"chill","kind":"integer","state":"configurable","value":60,"range":{"min":30,"max":120,"step":5},"restore":{"original":50,"written":60}},
        {"id":"vsync.mode","group":"vsync","kind":"choice","state":"configurable","value":"off","options":[{"value":"off","label":"Off"},{"value":"on","label":"Always on"}]},
        {"id":"future","group":"future","kind":"new_kind","state":"configurable","value":1},
        {"id":"setup","group":"setup","kind":"toggle","state":"needs_external_setup","value":false}
        ]}]}
        """#.utf8))
        XCTAssertTrue(panel.writable)
        let rows=panel.gpus[0].settings
        XCTAssertTrue(rows[0].accepts(.toggle(false)))
        XCTAssertFalse(rows[0].accepts(.integer(1)))
        XCTAssertTrue(rows[1].accepts(.integer(65)))
        XCTAssertFalse(rows[1].accepts(.integer(64)))
        XCTAssertFalse(rows[1].accepts(.integer(125)))
        XCTAssertEqual(rows[1].restore?.original,.integer(50))
        XCTAssertTrue(rows[2].accepts(.choice("on")))
        XCTAssertFalse(rows[2].accepts(.choice("unknown")))
        XCTAssertFalse(rows[3].editable)
        XCTAssertFalse(rows[4].editable)
        XCTAssertNotNil(rows[4].note)
    }
    func testHostControlAndOwnedSessionGateThePanel() throws {
        for (control,writable,state) in [(false,true,"configurable"),(true,false,"configurable"),(true,true,"future")] {
            let data=Data("{\"revision\":1,\"state\":\"\(state)\",\"host_control\":\(control),\"writable_now\":\(writable),\"gpus\":[]}".utf8)
            let panel=try JSONDecoder().decode(HostGraphics.self,from:data)
            XCTAssertFalse(panel.writable);XCTAssertNotNil(panel.notice)
        }
    }
}
