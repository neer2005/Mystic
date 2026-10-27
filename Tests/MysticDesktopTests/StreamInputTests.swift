import XCTest
import AppKit
import MysticCore
import MysticStream
@testable import MysticDesktop

@MainActor
final class StreamInputTests: XCTestCase {
    func testMailboxSchedulesOnceAndPreservesBoundaries() {
        let mailbox=StreamInputMailbox()
        XCTAssertTrue(mailbox.offer(.position(x:1,y:2,width:100,height:100)).schedule)
        XCTAssertFalse(mailbox.offer(.position(x:3,y:4,width:100,height:100)).schedule)
        XCTAssertFalse(mailbox.offer(.button(number:1,down:true)).schedule)
        XCTAssertFalse(mailbox.offer(.position(x:5,y:6,width:100,height:100)).schedule)
        let batch=mailbox.take()
        XCTAssertEqual(batch.events,[.position(x:3,y:4,width:100,height:100),.button(number:1,down:true),.position(x:5,y:6,width:100,height:100)])
        XCTAssertTrue(mailbox.isCurrent(batch.epoch))
        XCTAssertFalse(mailbox.finish())
    }
    func testReleaseInvalidatesTakenBatchAndClosesCleanly() {
        let mailbox=StreamInputMailbox()
        _=mailbox.offer(.key(code:0x8041,down:true,modifiers:0,flags:0))
        let old=mailbox.take()
        _=mailbox.offer(.releaseAll)
        XCTAssertFalse(mailbox.isCurrent(old.epoch))
        XCTAssertTrue(mailbox.finish())
        XCTAssertEqual(mailbox.take().events,[.releaseAll])
        XCTAssertFalse(mailbox.finish())
        mailbox.close()
        XCTAssertFalse(mailbox.offer(.motion(dx:1,dy:1)).accepted)
        XCTAssertFalse(mailbox.offer(.releaseAll).schedule)
    }
    func testOverflowBecomesReleaseWithoutExtraDrain() {
        let mailbox=StreamInputMailbox()
        for n in 0..<256 {
            let result=mailbox.offer(.key(code:UInt16(n),down:true,modifiers:0,flags:0))
            XCTAssertTrue(result.accepted)
            XCTAssertEqual(result.schedule,n==0)
        }
        let result=mailbox.offer(.button(number:1,down:true))
        XCTAssertFalse(result.accepted);XCTAssertFalse(result.schedule)
        XCTAssertEqual(mailbox.take().events,[.releaseAll])
        XCTAssertFalse(mailbox.finish())
    }
    func testCaptureNeverStartsWithoutConnectionOrVideo() {
        var events:[RemoteInputEvent]=[]
        let capture=StreamInputCapture(send:{ events.append($0);return true },failure:{ _ in })
        let presenter=DisplayLayerPresenter()
        let view=RemoteVideoView(presenter:presenter,capture:capture)
        capture.attach(view)
        capture.controlDesktop();capture.captureMouse()
        XCTAssertEqual(capture.mode,.released)
        capture.setAvailable(true)
        capture.controlDesktop();capture.captureMouse()
        XCTAssertEqual(capture.mode,.released)
        capture.release();capture.setAvailable(false)
        XCTAssertTrue(events.isEmpty)
        capture.detach(view)
    }
}
