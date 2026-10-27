import Testing
@testable import MysticCore

struct RemoteInputTests {
    @Test func physicalKeysAndWireFlags() {
        #expect(MacKeyboard.key(0)?.wireCode == 0x8041)
        #expect(MacKeyboard.key(51)?.virtualCode == 8)
        #expect(MacKeyboard.key(117)?.virtualCode == 0x2E)
        #expect(MacKeyboard.key(36)?.extended == false)
        #expect(MacKeyboard.key(76)?.extended == true)
        #expect(MacKeyboard.key(62)?.virtualCode == 0xA3)
        #expect(MacKeyboard.key(123)?.extended == true)
        #expect(MacKeyboard.key(63) == nil) // Fn stays local.
    }
    @Test func heldKeysAndTwoSidedModifiers() {
        var state=RemoteInputState()
        #expect({ state.modifier(56,rawFlags:2,capsLock:false) == [.key(code:0x80A0,down:true,modifiers:1,flags:0)] }())
        #expect({ state.modifier(60,rawFlags:6,capsLock:false) == [.key(code:0x80A1,down:true,modifiers:1,flags:0)] }())
        #expect({ state.modifier(56,rawFlags:4,capsLock:false) == [.key(code:0x80A0,down:false,modifiers:1,flags:0)] }())
        #expect({ state.key(0,down:true) == [.key(code:0x8041,down:true,modifiers:1,flags:0)] }())
        #expect({ state.key(0,down:true,repeatEvent:true).isEmpty }())
        #expect({ state.modifier(60,rawFlags:0,capsLock:false) == [.key(code:0x80A1,down:false,modifiers:0,flags:0)] }())
        #expect({ state.releaseAll() == .releaseAll }())
        #expect({ state.key(0,down:false).isEmpty }())
        #expect({ state.modifier(56,rawFlags:0,capsLock:false).isEmpty }())
    }
    @Test func capsAndMouseButtons() {
        var state=RemoteInputState()
        #expect({ state.modifier(57,rawFlags:0,capsLock:true).count == 2 }())
        #expect({ state.modifier(57,rawFlags:0,capsLock:true).isEmpty }())
        #expect({ state.button(1,down:true) == [.button(number:3,down:true)] }())
        #expect({ state.button(2,down:true) == [.button(number:2,down:true)] }())
        #expect({ state.button(1,down:true).isEmpty }())
        #expect({ state.button(1,down:false) == [.button(number:3,down:false)] }())
        #expect({ state.button(9,down:true).isEmpty }())
    }
    @Test func geometryAndFractionalMovement() {
        #expect(InputGeometry.position(x:10,y:110,left:10,bottom:10,width:200,height:100) == .position(x:0,y:0,width:32767,height:32767))
        #expect(InputGeometry.position(x:210,y:10,left:10,bottom:10,width:200,height:100) == .position(x:32766,y:32766,width:32767,height:32767))
        #expect(InputGeometry.position(x:5,y:50,left:10,bottom:10,width:200,height:100) == nil)
        #expect(InputGeometry.position(x:5,y:50,left:10,bottom:10,width:200,height:100,clamp:true) != nil)
        #expect(InputGeometry.position(x:.nan,y:50,left:10,bottom:10,width:200,height:100) == nil)
        var delta=InputDelta()
        let a=delta.consume(x:0.4,y:-0.4),b=delta.consume(x:0.7,y:-0.7)
        #expect(a.0==0 && a.1==0);#expect(b.0==1 && b.1 == -1)
        let big=delta.consume(x:1e20,y:-1e20)
        #expect(big.0 == Int16.max && big.1 == Int16.min)
    }
    @Test func coalescingAndOverflowRelease() {
        var queue=RemoteInputQueue(capacity:3)
        #expect({ queue.append(.motion(dx:1,dy:2)) }())
        #expect({ queue.append(.motion(dx:3,dy:4)) }())
        #expect({ queue.append(.button(number:1,down:true)) }())
        #expect({ queue.append(.motion(dx:5,dy:6)) }())
        #expect({ queue.take() == [.motion(dx:4,dy:6),.button(number:1,down:true),.motion(dx:5,dy:6)] }())
        for n in 1...4 { _=queue.append(.key(code:UInt16(n),down:true,modifiers:0,flags:0)) }
        #expect({ queue.take() == [.releaseAll] }())
    }
    @Test func releaseActualDeliveredKeysAndRetryFailures() throws {
        enum Failure: Error { case rejected }
        var delivery=RemoteInputDelivery(),events:[RemoteInputEvent]=[]
        try delivery.deliver(.key(code:0x80A0,down:true,modifiers:1,flags:0)) { events.append($0) }
        try delivery.deliver(.key(code:0x8041,down:true,modifiers:1,flags:0)) { events.append($0) }
        try delivery.deliver(.button(number:3,down:true)) { events.append($0) }
        events=[]
        do {
            try delivery.deliver(.releaseAll) { event in
                if case .key(code:0x8041,down:false,modifiers:_,flags:_) = event { throw Failure.rejected }
                events.append(event)
            }
            Issue.record("release should report the rejected key")
        } catch {}
        #expect(events == [.key(code:0x80A0,down:false,modifiers:0,flags:0),.button(number:3,down:false)])
        events=[]
        try delivery.deliver(.releaseAll) { events.append($0) }
        #expect(events == [.key(code:0x8041,down:false,modifiers:0,flags:0)])
        events=[];try delivery.deliver(.releaseAll) { events.append($0) };#expect(events.isEmpty)
    }
}
