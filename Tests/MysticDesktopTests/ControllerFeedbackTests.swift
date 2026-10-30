import XCTest
import GameController
import CoreHaptics
import MysticCore
@testable import MysticDesktop

@MainActor
final class ControllerFeedbackTests: XCTestCase {
    func testAdvertisesOnlyAvailableMotorsAndRoutesBySlotAndKind() {
        let first=GCController.withExtendedGamepad(),second=GCController.withExtendedGamepad()
        let handles=FakeControllerHaptics(capabilities:.rumble)
        let full=FakeControllerHaptics(capabilities:[.rumble,.triggerRumble])
        var events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ [first,second] },
            makeHaptics:{ $0 === first ? handles : full },
            send:{ events.append($0);return true },failure:{ XCTFail("Input failure") })
        manager.setEnabled(true)
        let epoch=manager.feedbackEpoch
        XCTAssertTrue(events.contains(.controllerArrival(slot:0,activeMask:3,capabilities:[.analogTriggers,.rumble],feedbackEpoch:epoch)))
        XCTAssertTrue(events.contains(.controllerArrival(slot:1,activeMask:3,capabilities:[.analogTriggers,.rumble,.triggerRumble],feedbackEpoch:epoch)))
        let rumble=ControllerFeedback(slot:0,kind:.rumble,first:0x1234,second:UInt16.max,epoch:epoch)
        let triggers=ControllerFeedback(slot:1,kind:.triggerRumble,first:700,second:900,epoch:epoch)
        manager.applyFeedback([rumble,triggers,
            .init(slot:0,kind:.triggerRumble,first:1,second:2,epoch:epoch),
            .init(slot:9,kind:.rumble,first:1,second:2,epoch:epoch)],epoch:epoch)
        XCTAssertEqual(handles.applied,[rumble]);XCTAssertEqual(full.applied,[triggers])
        let stop=ControllerFeedback(slot:0,kind:.rumble,first:0,second:0,epoch:epoch)
        manager.applyFeedback([stop],epoch:epoch)
        XCTAssertEqual(handles.applied.last,stop)
        manager.setEnabled(false)
        XCTAssertEqual(handles.stops,1);XCTAssertEqual(full.stops,1)
    }
    func testReleaseAndSlotReuseFencePendingFeedback() {
        let first=GCController.withExtendedGamepad(),replacement=GCController.withExtendedGamepad()
        var connected=[first]
        let old=FakeControllerHaptics(capabilities:.rumble),new=FakeControllerHaptics(capabilities:.rumble)
        let manager=StreamControllers(connectedDevices:{ connected },makeHaptics:{ $0 === first ? old : new },
            send:{ _ in true },failure:{ XCTFail("Input failure") })
        manager.setEnabled(true)
        let epoch=manager.feedbackEpoch
        let stale=ControllerFeedback(slot:0,kind:.rumble,first:UInt16.max,second:UInt16.max,epoch:epoch)
        manager.setEnabled(false);manager.applyFeedback([stale],epoch:epoch)
        XCTAssertTrue(old.applied.isEmpty);XCTAssertEqual(old.stops,1)
        manager.setEnabled(true)
        connected=[replacement];manager.refresh()
        XCTAssertEqual(old.stops,2)
        // Reject both an old poll and a stale item returned by a poll using the new epoch.
        manager.applyFeedback([stale],epoch:epoch)
        manager.applyFeedback([stale],epoch:manager.feedbackEpoch)
        XCTAssertTrue(new.applied.isEmpty)
        let fresh=ControllerFeedback(slot:0,kind:.rumble,first:1,second:2,epoch:manager.feedbackEpoch)
        manager.applyFeedback([fresh],epoch:manager.feedbackEpoch)
        XCTAssertEqual(new.applied,[fresh])
        connected=[];manager.refresh();XCTAssertEqual(new.stops,1)
        manager.setEnabled(false)
    }
    func testMotorFailureStopsFeedbackWithoutDisablingControllerInput() {
        let controller=GCController.withExtendedGamepad(),motor=FakeControllerHaptics(capabilities:.rumble)
        motor.reject=true
        var warnings:[String]=[],events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ [controller] },makeHaptics:{ _ in motor },
            feedbackFailure:{ warnings.append($0) },send:{ events.append($0);return true },failure:{ XCTFail("Input should remain active") })
        manager.setEnabled(true)
        let feedback=ControllerFeedback(slot:0,kind:.rumble,first:1,second:2,epoch:manager.feedbackEpoch)
        manager.applyFeedback([feedback,feedback],epoch:manager.feedbackEpoch)
        XCTAssertEqual(warnings.count,1);XCTAssertEqual(motor.stops,1)
        XCTAssertNotNil(controller.extendedGamepad?.valueChangedHandler)
        XCTAssertTrue(events.contains(.controllerArrival(slot:0,activeMask:1,capabilities:.analogTriggers,feedbackEpoch:manager.feedbackEpoch)))
        manager.setEnabled(false)
    }
    func testMissingHapticsKeepBasicControllerSupport() {
        let controller=GCController.withExtendedGamepad()
        var events:[RemoteInputEvent]=[]
        let manager=StreamControllers(connectedDevices:{ [controller] },makeHaptics:{ _ in nil },
            send:{ events.append($0);return true },failure:{ XCTFail("Input failure") })
        manager.setEnabled(true)
        XCTAssertTrue(events.contains(.controllerArrival(slot:0,activeMask:1,feedbackEpoch:manager.feedbackEpoch)))
        manager.applyFeedback([.init(slot:0,kind:.rumble,first:1,second:2,epoch:manager.feedbackEpoch)],epoch:manager.feedbackEpoch)
        XCTAssertNotNil(controller.extendedGamepad?.valueChangedHandler)
        manager.setEnabled(false)
    }
    func testContinuousControllerPatternsAreAcceptedByCoreHaptics() throws {
        // Real framework validation catches invalid controller-duration or dynamic-parameter syntax.
        for intensity:Float in [0.001,0.5,1] {
            _=try NativeControllerHaptics.pattern(intensity:intensity,sharpness:0)
            _=try NativeControllerHaptics.pattern(intensity:intensity,sharpness:1)
        }
    }
}

@MainActor
private final class FakeControllerHaptics: ControllerHaptics {
    let capabilities: ControllerCapabilities
    var applied:[ControllerFeedback]=[]
    var stops=0,reject=false
    init(capabilities:ControllerCapabilities) { self.capabilities=capabilities }
    func apply(_ feedback:ControllerFeedback) throws {
        if reject { throw NSError(domain:"HapticsTest",code:1) }
        applied.append(feedback)
    }
    func stop() { stops+=1 }
}
