import Testing
@testable import MysticCore

struct ControllerInputTests {
    @Test func analogLimitsAndInvalidValues() {
        #expect(ControllerState.trigger(0.5) == 128)
        #expect(ControllerState.trigger(-1) == 0)
        #expect(ControllerState.trigger(2) == 255)
        #expect(ControllerState.trigger(.nan) == 0)
        let positive=ControllerState.stick(x:1,y:0),negative=ControllerState.stick(x:0,y:-1)
        #expect(positive.0 == 32767 && positive.1 == 0)
        #expect(negative.0 == 0 && negative.1 == -32768)
        let noise=ControllerState.stick(x:0.05,y:0.05),invalid=ControllerState.stick(x:.infinity,y:1)
        #expect(noise.0 == 0 && noise.1 == 0 && invalid.0 == 0 && invalid.1 == 0)
        let diagonal=ControllerState.stick(x:1,y:1)
        #expect(diagonal.0 == 23170 && diagonal.1 == 23170)
    }
    @Test func analogCoalescingPreservesButtonAndTriggerEdges() {
        var q=RemoteInputQueue(capacity:5)
        let a=RemoteInputEvent.controller(slot:0,activeMask:1,state:ControllerState(leftX:1))
        let b=RemoteInputEvent.controller(slot:0,activeMask:1,state:ControllerState(leftX:2))
        let c=RemoteInputEvent.controller(slot:0,activeMask:1,state:ControllerState(buttons:0x1000))
        let d=RemoteInputEvent.controller(slot:0,activeMask:1,state:ControllerState(leftTrigger:255))
        let accepted=[q.append(a),q.append(b),q.append(c),q.append(d)]
        #expect(accepted == [true,true,true,true])
        #expect(q.take() == [b,c,d])
    }
    @Test func releaseOnlyAcceptedSlotsAndRetryFailure() throws {
        enum Failure: Error { case transport }
        var delivery=RemoteInputDelivery(),sent:[RemoteInputEvent]=[]
        try delivery.deliver(.controller(slot:2,activeMask:4,state:ControllerState(buttons:0x1000))) { sent.append($0) }
        do { try delivery.deliver(.releaseAll) { _ in throw Failure.transport } } catch {}
        try delivery.deliver(.releaseAll) { sent.append($0) }
        #expect(sent.last == .controller(slot:2,activeMask:0,state:ControllerState()))
        let count=sent.count
        try delivery.deliver(.releaseAll) { sent.append($0) }
        #expect(sent.count == count)
    }
}
