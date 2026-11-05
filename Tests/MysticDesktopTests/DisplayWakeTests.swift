import XCTest
@testable import MysticDesktop

@MainActor
final class DisplayWakeTests: XCTestCase {
    func testOneHoldPerStreamReleasedOnceAndRealActivitiesWork() {
        var begun=0,ended=0
        let wake=DisplayWake(begin:{ begun+=1;return NSObject() },end:{ _ in ended+=1 })
        wake.update(streaming:false);XCTAssertEqual(begun,0)
        wake.update(streaming:true);wake.update(streaming:true)
        XCTAssertTrue(wake.held);XCTAssertEqual(begun,1)
        wake.update(streaming:false);wake.update(streaming:false)
        XCTAssertFalse(wake.held);XCTAssertEqual(ended,1)
        // The real ProcessInfo activity can be taken and given back.
        let native=DisplayWake()
        native.update(streaming:true);XCTAssertTrue(native.held)
        native.update(streaming:false);XCTAssertFalse(native.held)
    }
    func testStreamingAsksForPreciseTimersAndAwakeDisplay() {
        XCTAssertTrue(DisplayWake.activityOptions.contains(.latencyCritical))
        XCTAssertTrue(DisplayWake.activityOptions.contains(.idleDisplaySleepDisabled))
    }
}
