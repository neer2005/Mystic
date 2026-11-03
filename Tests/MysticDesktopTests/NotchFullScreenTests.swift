import XCTest
import AppKit
@testable import MysticDesktop

@MainActor
final class NotchFullScreenTests: XCTestCase {
    private let fourteenInch=NSRect(x:0,y:0,width:1512,height:982),sixteenInch=NSRect(x:0,y:0,width:1728,height:1117)
    func testFullPanelStreamsCoverTheNotch() {
        XCTAssertTrue(NotchFullScreen.coversNotch(video:CGSize(width:3024,height:1964),screen:fourteenInch,topInset:32))
        XCTAssertTrue(NotchFullScreen.coversNotch(video:CGSize(width:1512,height:982),screen:fourteenInch,topInset:32),"Any size of the panel's shape")
        XCTAssertTrue(NotchFullScreen.coversNotch(video:CGSize(width:3456,height:2234),screen:sixteenInch,topInset:32))
        XCTAssertTrue(NotchFullScreen.coversNotch(video:CGSize(width:3456,height:2234),screen:fourteenInch,topInset:32),"The 16-inch shape is within 1% of the 14-inch")
    }
    func testOtherShapesStayBelowTheCamera() {
        for size in [CGSize(width:3024,height:1890),CGSize(width:1920,height:1080),CGSize(width:2560,height:1600),CGSize(width:1024,height:768)] {
            XCTAssertFalse(NotchFullScreen.coversNotch(video:size,screen:fourteenInch,topInset:32),"\(size)")
        }
    }
    func testNoNotchOrNoPictureKeepsAppKitFullScreen() {
        XCTAssertFalse(NotchFullScreen.coversNotch(video:CGSize(width:3024,height:1964),screen:fourteenInch,topInset:0))
        XCTAssertFalse(NotchFullScreen.coversNotch(video:.zero,screen:fourteenInch,topInset:32))
    }
}
