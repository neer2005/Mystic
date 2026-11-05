import XCTest
import GameController
import MysticCore
@testable import MysticDesktop

@ControllerActor
final class StreamMouseTests: XCTestCase {
    func testMotionIsSentDownwardScaledAndOnlyWhileCaptured() async {
        let sent=SentInput()
        let mouse=StreamMouse(connectedMice:{ [] },send:{ sent.append($0);return true },failure:{ XCTFail("Unexpected failure") })
        mouse.moved(dx:5,dy:5)
        XCTAssertTrue(sent.all.isEmpty,"nothing before capture")
        mouse.setEnabled(true,scale:2)
        mouse.moved(dx:3,dy:4)
        XCTAssertEqual(sent.all,[.motion(dx:6,dy:-8)],"GameController's y runs up, the host's down")
        mouse.setEnabled(true,scale:0.5)
        mouse.moved(dx:1,dy:0);mouse.moved(dx:1,dy:0)
        XCTAssertEqual(sent.all.last,.motion(dx:1,dy:0),"half counts add up rather than vanish")
        XCTAssertEqual(sent.all.count,2)
        mouse.setEnabled(false,scale:1)
        mouse.moved(dx:9,dy:9)
        XCTAssertEqual(sent.all.count,2,"nothing after release")
    }
    func testAFullBacklogStopsTheMouseAndSaysSoOnce() async {
        let failures=SentInput()
        let mouse=StreamMouse(connectedMice:{ [] },send:{ _ in false },failure:{ failures.append(.releaseAll) })
        mouse.setEnabled(true,scale:1)
        mouse.moved(dx:4,dy:0);mouse.moved(dx:4,dy:0)
        XCTAssertEqual(failures.all.count,1)
    }
    nonisolated func testAppKitMotionIsDroppedOnlyWhileAGameControllerMouseReports() {
        let clock=FakeClock()
        let activity=MouseMotionActivity(now:{ clock.value })
        XCTAssertFalse(activity.covers,"a device GameController never saw keeps working")
        clock.value=1_000_000_000;activity.mark()
        clock.value += MouseMotionActivity.window-1
        XCTAssertTrue(activity.covers)
        clock.value += 1
        XCTAssertFalse(activity.covers,"a pause hands motion back to AppKit")
        activity.mark();activity.clear()
        XCTAssertFalse(activity.covers)
    }
    func testCaptureStartsWithTheMiceConnectedThen() async {
        var asked=0
        let mouse=StreamMouse(connectedMice:{ asked += 1;return [] },send:{ _ in true },failure:{})
        mouse.setEnabled(true,scale:1);mouse.setEnabled(true,scale:1)
        XCTAssertEqual(asked,1)
        mouse.setEnabled(false,scale:1);mouse.setEnabled(true,scale:1)
        XCTAssertEqual(asked,2)
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock=NSLock()
    private var now: UInt64=0
    var value: UInt64 {
        get { lock.withLock { now } }
        set { lock.withLock { now=newValue } }
    }
}
