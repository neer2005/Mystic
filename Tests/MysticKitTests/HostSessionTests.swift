import XCTest
@testable import MysticKit

final class HostSessionTests: XCTestCase {
    func testMissingAndUnknownActionsNeverGrantPermission() throws {
        let session=try JSONDecoder().decode(HostSession.self,from:Data(#"{"state":"future_state","owner":"other","app":null,"game_running":false,"actions":[{"id":"future_action","allowed":true},{"id":"close_game","allowed":false,"reason":"host_control_required"}]}"#.utf8))
        XCTAssertFalse(session.allows(.disconnect))
        XCTAssertFalse(session.allows(.end))
        XCTAssertFalse(session.allows(.closeGame))
        XCTAssertEqual(session.blockedReason(.closeGame),"Allow Host control for this device on the host.")
        XCTAssertNotNil(session.blockedReason(.end))
    }
}
