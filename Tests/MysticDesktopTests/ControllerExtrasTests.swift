import XCTest
import GameController
import MysticCore
@testable import MysticDesktop

@MainActor
final class ControllerExtrasTests: XCTestCase {
    func testArrivalAdvertisesExtrasAndBatteryFollowsIt() {
        let controller=GCController.withExtendedGamepad(),other=GCController.withExtendedGamepad()
        let extras=FakeControllerExtras(capabilities:[.accelerometer,.gyroscope,.battery,.light])
        extras.initialBattery=ControllerBattery(state:.charging,level:0.8)
        var connected=[controller],events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ connected },makeHaptics:{ _ in nil },
            makeExtras:{ $0 === controller ? extras : FakeControllerExtras(capabilities:[]) },
            send:{ events.append($0);return true },failure:{ XCTFail("Input failure") })
        manager.setEnabled(true)
        let caps: ControllerCapabilities=[.analogTriggers,.accelerometer,.gyroscope,.battery,.light]
        let battery=RemoteInputEvent.controllerBattery(slot:0,battery:ControllerBattery(state:.charging,percent:80))
        XCTAssertEqual(Array(events.prefix(2)),[.arrival(controller,slot:0,mask:1,capabilities:caps,epoch:manager.feedbackEpoch,extras:false),battery])
        // A hot-plug re-announces every controller; the host hears its battery again.
        events.removeAll();connected.append(other);manager.refresh()
        XCTAssertEqual(Array(events.prefix(2)),[.arrival(controller,slot:0,mask:3,capabilities:caps,epoch:manager.feedbackEpoch,extras:false),battery])
        manager.setEnabled(false)
        XCTAssertEqual(extras.stops,1)
    }
    func testMotionOffStopsSensorsAndIsNoLongerAdvertised() {
        let controller=GCController.withExtendedGamepad(),extras=FakeControllerExtras(capabilities:[.gyroscope,.accelerometer])
        var events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ [controller] },makeHaptics:{ _ in nil },makeExtras:{ _ in extras },
            send:{ events.append($0);return true },failure:{ XCTFail("Input failure") })
        manager.setEnabled(true)
        events.removeAll()
        var settings=InputPreferences();settings.controllerMotion=false;manager.settings=settings
        XCTAssertEqual(extras.rates.map(\.1),[0,0])
        XCTAssertTrue(events.contains(.arrival(controller,slot:0,mask:1,capabilities:.analogTriggers,epoch:manager.feedbackEpoch,extras:false)))
        extras.rates.removeAll()
        manager.applyFeedback([.init(slot:0,kind:.gyroscopeRate,first:100,second:0,epoch:manager.feedbackEpoch)],epoch:manager.feedbackEpoch)
        XCTAssertTrue(extras.rates.isEmpty)
        manager.setEnabled(false)
    }
    func testLightAndMotionRatesReachOnlyControllersThatHaveThem() {
        let lit=GCController.withExtendedGamepad(),plain=GCController.withExtendedGamepad()
        let light=FakeControllerExtras(capabilities:[.light,.gyroscope]),none=FakeControllerExtras(capabilities:[])
        let manager=StreamControllers(connectedDevices:{ [lit,plain] },makeHaptics:{ _ in nil },
            makeExtras:{ $0 === lit ? light : none },send:{ _ in true },failure:{ XCTFail("Input failure") })
        manager.setEnabled(true)
        let epoch=manager.feedbackEpoch
        manager.applyFeedback([
            .init(slot:0,kind:.light,first:0x1234,second:0x56,epoch:epoch),
            .init(slot:0,kind:.gyroscopeRate,first:250,second:0,epoch:epoch),
            .init(slot:0,kind:.accelerometerRate,first:100,second:0,epoch:epoch),
            .init(slot:1,kind:.light,first:0xFFFF,second:0xFF,epoch:epoch),
            .init(slot:1,kind:.gyroscopeRate,first:250,second:0,epoch:epoch),
            .init(slot:0,kind:.light,first:1,second:2,epoch:epoch &+ 1),
        ],epoch:epoch)
        XCTAssertEqual(light.lights.map { [$0.0,$0.1,$0.2] },[[0x12,0x34,0x56]])
        XCTAssertEqual(light.rates.map { "\($0.0)=\($0.1)" },["gyroscope=250"],"no accelerometer on this pad")
        XCTAssertTrue(none.lights.isEmpty && none.rates.isEmpty)
        manager.applyFeedback([.init(slot:0,kind:.light,first:9,second:9,epoch:epoch)],epoch:epoch &+ 1)
        XCTAssertEqual(light.lights.count,1,"a stale poll is dropped")
        manager.setEnabled(false)
    }
    func testMotionFromAReleasedOrReplacedControllerIsDropped() {
        let first=GCController.withExtendedGamepad(),second=GCController.withExtendedGamepad()
        let old=FakeControllerExtras(capabilities:[.gyroscope]),new=FakeControllerExtras(capabilities:[.gyroscope])
        var connected=[first],events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ connected },makeHaptics:{ _ in nil },
            makeExtras:{ $0 === first ? old : new },send:{ events.append($0);return true },failure:{ XCTFail("Input failure") })
        manager.setEnabled(true)
        old.motion?(.gyroscope,1,2,3)
        XCTAssertEqual(events.last,.controllerMotion(slot:0,kind:.gyroscope,x:1,y:2,z:3))
        connected=[second];manager.refresh()
        XCTAssertEqual(old.stops,1)
        events.removeAll()
        old.motion?(.gyroscope,4,5,6);old.battery?(ControllerBattery(state:.full,percent:100))
        XCTAssertFalse(events.contains { if case .controllerMotion = $0 { return true };return false })
        XCTAssertFalse(events.contains { if case .controllerBattery = $0 { return true };return false })
        new.motion?(.gyroscope,7,8,9)
        XCTAssertEqual(events.last,.controllerMotion(slot:0,kind:.gyroscope,x:7,y:8,z:9))
        manager.setEnabled(false)
        new.motion?(.gyroscope,1,1,1)
        XCTAssertEqual(events.last,.controllerMotion(slot:0,kind:.gyroscope,x:7,y:8,z:9),"nothing after release")
    }
    func testGenericPadKeepsClassicButtonsAndGuideFollowsHome() throws {
        let controller=GCController.withExtendedGamepad()
        let pad=try XCTUnwrap(controller.extendedGamepad)
        XCTAssertEqual(StreamControllers.kind(controller),.unknown)
        let buttons=StreamControllers.buttons(pad)
        XCTAssertEqual(buttons & ControllerButtons.classic,ControllerButtons.classic)
        XCTAssertEqual(buttons & (ControllerButtons.touchpad | ControllerButtons.misc),0,"a generic pad has no touchpad or Share")
        XCTAssertEqual(buttons & ControllerButtons.guide != 0,pad.buttonHome != nil)
        if let home=pad.buttonHome {
            home.setValue(1)
            XCTAssertEqual(StreamControllers.snapshot(pad).buttons,ControllerButtons.guide)
            home.setValue(0)
        }
    }
    func testBatteryLevelsBecomeMoonlightPercentages() {
        XCTAssertEqual(ControllerBattery(state:.discharging,level:0.456).percent,46)
        XCTAssertEqual(ControllerBattery(state:.full,level:1).percent,100)
        for level in [Float(-0.1),1.1,.nan,.infinity] { XCTAssertEqual(ControllerBattery(state:.unknown,level:level).percent,0xFF) }
    }
}

@MainActor
private final class FakeControllerExtras: ControllerExtras {
    let capabilities: ControllerCapabilities
    var initialBattery: ControllerBattery?
    var motion: ((ControllerMotionKind,Float,Float,Float) -> Void)?
    var battery: ((ControllerBattery) -> Void)?
    var lights:[(UInt8,UInt8,UInt8)]=[],rates:[(ControllerMotionKind,UInt16)]=[]
    var stops=0
    init(capabilities: ControllerCapabilities) { self.capabilities=capabilities }
    func start(motion: @escaping (ControllerMotionKind,Float,Float,Float) -> Void,battery: @escaping (ControllerBattery) -> Void) {
        self.motion=motion;self.battery=battery
        if let initialBattery { battery(initialBattery) }
    }
    func setLight(red: UInt8,green: UInt8,blue: UInt8) { lights.append((red,green,blue)) }
    func setMotion(_ kind: ControllerMotionKind,rateHz: UInt16) { rates.append((kind,rateHz)) }
    func stop() { stops+=1 }
}
