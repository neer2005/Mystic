import XCTest
import GameController
import MysticCore
@testable import MysticDesktop

@MainActor
final class StreamControllerTests: XCTestCase {
    func testPositionalFaceButtonsAndAnalogSnapshot() throws {
        let controller=GCController.withExtendedGamepad()
        let pad=try XCTUnwrap(controller.extendedGamepad)
        let buttons:[(GCControllerButtonInput?,UInt32)] = [
            (pad.buttonMenu,0x10),(pad.buttonOptions,0x20),(pad.leftThumbstickButton,0x40),
            (pad.rightThumbstickButton,0x80),(pad.leftShoulder,0x100),(pad.rightShoulder,0x200),
            (pad.buttonA,0x1000),(pad.buttonB,0x2000),(pad.buttonX,0x4000),(pad.buttonY,0x8000),
        ]
        for (button,flag) in buttons {
            let button=try XCTUnwrap(button)
            button.setValue(1)
            XCTAssertEqual(StreamControllers.snapshot(pad).buttons,flag)
            button.setValue(0)
        }
        for (x,y,flag) in [(Float(0),Float(1),UInt32(1)),(0,-1,2),(-1,0,4),(1,0,8),(1,1,9)] {
            pad.dpad.setValueForXAxis(x,yAxis:y)
            XCTAssertEqual(StreamControllers.snapshot(pad).buttons,flag)
        }
        pad.dpad.setValueForXAxis(0,yAxis:0)
        pad.leftTrigger.setValue(0.5);pad.rightTrigger.setValue(1)
        pad.leftThumbstick.setValueForXAxis(-1,yAxis:0)
        pad.rightThumbstick.setValueForXAxis(0,yAxis:1)
        XCTAssertEqual(StreamControllers.snapshot(pad),ControllerState(leftTrigger:128,rightTrigger:255,leftX:-32768,rightY:32767))
    }
    func testDiscoverySlotsReleaseReconnectAndCapacity() {
        let all=(0..<5).map { _ in GCController.withExtendedGamepad() }
        var connected=all,events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ connected },send:{ events.append($0);return true },failure:{ XCTFail("Unexpected overflow") })
        manager.refresh();XCTAssertTrue(events.isEmpty)
        manager.setEnabled(true)
        XCTAssertEqual(events.filter { if case .controllerArrival = $0 { return true };return false }.count,4)
        XCTAssertTrue(events.contains(.controllerArrival(slot:3,activeMask:15)))
        events.removeAll()
        connected=[all[1],all[2],all[3]]
        manager.refresh()
        XCTAssertEqual(events.first,.controller(slot:0,activeMask:14,state:ControllerState()))
        XCTAssertTrue(events.contains(.controllerArrival(slot:1,activeMask:14)))
        connected.append(all[4]);events.removeAll();manager.refresh()
        XCTAssertTrue(events.contains(.controllerArrival(slot:0,activeMask:15)))
        let count=events.count
        manager.setEnabled(false);manager.refresh()
        XCTAssertEqual(events.count,count)
        manager.setEnabled(true)
        XCTAssertGreaterThan(events.count,count)
        manager.setEnabled(false)
    }
    func testValueCallbacksAndCallbacksAfterReleaseOrUnplug() throws {
        let controller=GCController.withExtendedGamepad()
        let pad=try XCTUnwrap(controller.extendedGamepad)
        var connected=[controller],events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ connected },send:{ events.append($0);return true },failure:{ XCTFail("Unexpected failure") })
        manager.setEnabled(true)
        let callback=try XCTUnwrap(pad.valueChangedHandler)
        pad.buttonA.setValue(1);callback(pad,pad.buttonA)
        XCTAssertEqual(events.last,.controller(slot:0,activeMask:1,state:ControllerState(buttons:0x1000)))
        manager.setEnabled(false)
        let released=events.count
        callback(pad,pad.buttonA)
        XCTAssertEqual(events.count,released)
        manager.setEnabled(true)
        connected=[];manager.refresh()
        XCTAssertEqual(events.last,.controller(slot:0,activeMask:0,state:ControllerState()))
        let unplugged=events.count
        callback(pad,pad.buttonA)
        XCTAssertEqual(events.count,unplugged)
        manager.setEnabled(false)
    }
    func testBacklogFailureDisablesDiscoveryAndLateCallbacks() {
        let controller=GCController.withExtendedGamepad()
        var failures=0,attempts=0
        let manager=StreamControllers(connectedDevices:{ [controller] },send:{ _ in attempts+=1;return false },failure:{ failures+=1 })
        manager.setEnabled(true)
        XCTAssertEqual(failures,1);XCTAssertEqual(attempts,1)
        manager.refresh()
        XCTAssertEqual(attempts,1)
        XCTAssertNil(controller.extendedGamepad?.valueChangedHandler)
    }
}
