import XCTest
import AppKit
@testable import MysticDesktop

@MainActor
final class StreamDockTests: XCTestCase {
    private let appKitFullScreen: NSApplication.PresentationOptions=[.fullScreen,.autoHideDock,.autoHideMenuBar,.autoHideToolbar]

    func testControllingAFullScreenStreamHidesTheDockAndKeepsTheToolbarRule() throws {
        let next=try XCTUnwrap(StreamDock.options(appKitFullScreen,fullScreen:true,controlling:true))
        XCTAssertTrue(next.contains(.hideDock));XCTAssertFalse(next.contains(.autoHideDock))
        // autoHideToolbar needs fullScreen and autoHideMenuBar, so neither may go.
        XCTAssertTrue(next.isSuperset(of:[.fullScreen,.autoHideMenuBar,.autoHideToolbar]))
        XCTAssertFalse(next.contains(.hideMenuBar))
    }
    func testReleasingInputGivesTheAutoHiddenDockBack() throws {
        let hidden=try XCTUnwrap(StreamDock.options(appKitFullScreen,fullScreen:true,controlling:true))
        XCTAssertEqual(StreamDock.options(hidden,fullScreen:true,controlling:false),appKitFullScreen)
    }
    func testWindowedStreamsAndRepeatsLeaveOptionsAlone() throws {
        XCTAssertNil(StreamDock.options([],fullScreen:false,controlling:true))
        let hidden=try XCTUnwrap(StreamDock.options(appKitFullScreen,fullScreen:true,controlling:true))
        XCTAssertNil(StreamDock.options(hidden,fullScreen:true,controlling:true))
        XCTAssertNil(StreamDock.options(appKitFullScreen,fullScreen:true,controlling:false))
    }
    func testLeavingFullScreenWhileHiddenRestoresAValidCombination() {
        // A hidden Dock left over outside full screen goes, without an orphaned auto-hide menu bar.
        XCTAssertEqual(StreamDock.options([.hideDock],fullScreen:false,controlling:false),[])
        XCTAssertEqual(StreamDock.options([.hideDock,.autoHideMenuBar],fullScreen:false,controlling:false),[.autoHideDock,.autoHideMenuBar])
    }
}

final class ControllerSteeringTests: XCTestCase {
    func testDirectionsStartPastThePressThreshold() {
        XCTAssertNil(ControllerSteering.direction(x:0.5,y:0,current:nil))
        XCTAssertEqual(ControllerSteering.direction(x:0.7,y:0.2,current:nil),.right)
        XCTAssertEqual(ControllerSteering.direction(x:-1,y:0,current:nil),.left)
        XCTAssertEqual(ControllerSteering.direction(x:0.1,y:0.9,current:nil),.up)
        XCTAssertEqual(ControllerSteering.direction(x:0,y:-1,current:nil),.down)
    }
    func testAHeldDirectionHoldsUntilTheStickFallsBack() {
        XCTAssertEqual(ControllerSteering.direction(x:0.4,y:0,current:.right),.right)
        XCTAssertNil(ControllerSteering.direction(x:0.3,y:0,current:.right))
        // Swinging to another axis below the press threshold doesn't move until it is past it.
        XCTAssertNil(ControllerSteering.direction(x:0.1,y:0.5,current:.right))
        XCTAssertEqual(ControllerSteering.direction(x:0.1,y:0.8,current:.right),.up)
    }
}
