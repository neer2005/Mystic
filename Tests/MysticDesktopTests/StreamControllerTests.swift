import XCTest
import GameController
import MysticCore
@testable import MysticDesktop

@ControllerActor
final class StreamControllerTests: XCTestCase {
    func testPositionalFaceButtonsAndAnalogSnapshot() async throws {
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
    func testDiscoverySlotsReleaseReconnectAndCapacity() async {
        let all=(0..<17).map { _ in GCController.withExtendedGamepad() }
        var connected=all,events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ connected },send:{ events.append($0);return true },failure:{ XCTFail("Unexpected overflow") })
        manager.refresh();XCTAssertTrue(events.isEmpty)
        manager.setEnabled(true)
        XCTAssertEqual(events.filter { if case .controllerArrival = $0 { return true };return false }.count,16)
        XCTAssertTrue(events.contains(.arrival(all[15],slot:15,mask:0xFFFF,epoch:manager.feedbackEpoch)))
        events.removeAll()
        connected=Array(all[1..<16])
        manager.refresh()
        XCTAssertEqual(events.first,.controller(slot:0,activeMask:0xFFFE,state:ControllerState()))
        XCTAssertTrue(events.contains(.arrival(all[1],slot:1,mask:0xFFFE,epoch:manager.feedbackEpoch)))
        connected.append(all[16]);events.removeAll();manager.refresh()
        XCTAssertTrue(events.contains(.arrival(all[16],slot:0,mask:0xFFFF,epoch:manager.feedbackEpoch)))
        let count=events.count
        manager.setEnabled(false);manager.refresh()
        XCTAssertEqual(events.count,count)
        manager.setEnabled(true)
        XCTAssertGreaterThan(events.count,count)
        manager.setEnabled(false)
    }
    func testValueCallbacksAndCallbacksAfterReleaseOrUnplug() async throws {
        let controller=GCController.withExtendedGamepad()
        let pad=try XCTUnwrap(controller.extendedGamepad)
        var connected=[controller],events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ connected },send:{ events.append($0);return true },failure:{ XCTFail("Unexpected failure") })
        manager.setEnabled(true)
        XCTAssertTrue(controller.handlerQueue === ControllerActor.queue,"GameController calls in on the controller queue, not main")
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
    /// The main actor waits for the controller queue, behind what is already on it, as a release
    /// does; on the queue itself the call runs inline.
    nonisolated func testRunWaitsFromMainAndRunsInlineOnTheQueue() async {
        let order=SentInput()
        let ran=await MainActor.run {
            ControllerActor.queue.async { Thread.sleep(forTimeInterval:0.05);order.append(.releaseAll) }
            return ControllerActor.run { order.all }
        }
        XCTAssertEqual(ran,[.releaseAll],"work already on the queue finishes first")
        let nested=ControllerActor.run { ControllerActor.run { 42 } }
        XCTAssertEqual(nested,42,"no deadlock when already on the queue")
    }
    func testBacklogFailureDisablesDiscoveryAndLateCallbacks() async {
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

extension RemoteInputEvent {
    /// The arrival a test controller gets: its own type, buttons and sensors, as the manager
    /// reads them (Apple's virtual pad has an accelerometer). `extras: false` for fake extras.
    @ControllerActor static func arrival(_ controller: GCController,slot: UInt8,mask: UInt16,
                                   capabilities: ControllerCapabilities = .analogTriggers,epoch: UInt64,extras: Bool = true) -> RemoteInputEvent {
        let native=extras ? NativeControllerExtras.capabilities(of:controller) : []
        return .controllerArrival(slot:slot,activeMask:mask,capabilities:capabilities.union(native),feedbackEpoch:epoch,
                           kind:StreamControllers.kind(controller),buttons:StreamControllers.buttons(controller.extendedGamepad!))
    }
}
