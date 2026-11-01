import AppKit
import XCTest
import MysticCore
@testable import MysticDesktop

@MainActor
final class HostCursorTests: XCTestCase {
    private func image(_ width: Int,_ height: Int,scale: Int = 100,hotspot: (Int,Int) = (0,0)) -> HostCursorImage {
        HostCursorImage(width:width,height:height,hotspotX:hotspot.0,hotspotY:hotspot.1,scalePercent:scale,
                        rgba:[UInt8](repeating:255,count:width*height*4))
    }
    func testImagesAreCachedAndShownAgainByID() {
        let cursor=HostCursor()
        var failures: [String]=[]
        cursor.failure={ failures.append($0) }
        cursor.apply(.image(id:7,image:image(32,32)))
        let first=cursor.current
        XCTAssertFalse(first === NSCursor.arrow)
        cursor.apply(.standard)
        XCTAssertTrue(cursor.current === NSCursor.arrow)
        cursor.apply(.show(id:7))
        XCTAssertTrue(cursor.current === first)
        cursor.apply(.show(id:8))
        XCTAssertTrue(cursor.current === NSCursor.arrow,"an id never sent falls back to the Mac pointer")
        cursor.apply(.rejected)
        XCTAssertEqual(failures.count,2)
        cursor.reset()
        cursor.apply(.show(id:7))
        XCTAssertTrue(cursor.current === NSCursor.arrow,"a reset forgets the host's images")
    }
    func testTheCacheKeepsTheMostRecentlyUsed() {
        let cursor=HostCursor()
        for id in 1...UInt32(HostCursor.cacheEntries) { cursor.apply(.image(id:id,image:image(2,2))) }
        cursor.apply(.show(id:1))
        let one=cursor.current
        cursor.apply(.image(id:99,image:image(2,2)))
        cursor.apply(.show(id:1))
        XCTAssertTrue(cursor.current === one,"shown recently, so kept")
        cursor.apply(.show(id:2))
        XCTAssertTrue(cursor.current === NSCursor.arrow,"the least recently used went")
    }
    func testTheImageTakesTheHostScaleAndKeepsItsHotspotInside() throws {
        let cursor=try XCTUnwrap(HostCursor.cursor(image(64,48,scale:200,hotspot:(63,47))))
        XCTAssertEqual(cursor.image.size,NSSize(width:32,height:24))
        XCTAssertEqual(cursor.hotSpot,NSPoint(x:31,y:23))
        XCTAssertNil(HostCursor.cursor(HostCursorImage(width:2,height:2,hotspotX:0,hotspotY:0,scalePercent:100,rgba:[0])))
    }
    func testAHideWaitsAndAShowCancelsIt() async throws {
        let cursor=HostCursor(hideDelay:.milliseconds(40))
        cursor.apply(.standard)
        cursor.apply(.hide)
        XCTAssertTrue(cursor.current === NSCursor.arrow,"not yet")
        cursor.apply(.standard)
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertTrue(cursor.current === NSCursor.arrow,"the show came first")
        cursor.apply(.hide)
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertTrue(cursor.current === HostCursor.hidden)
    }
}
