import Foundation
import Testing
@testable import MysticCore

struct ControllerMouseTests {
    private let start: UInt32=0x10,a: UInt32=0x1000,b: UInt32=0x2000,x: UInt32=0x4000,y: UInt32=0x8000

    private func activeMouse(precise: Bool = false) -> ControllerMouse {
        var mouse=ControllerMouse()
        _=mouse.update(ControllerState(buttons:start),enabled:true,precise:precise,nowMillis:0)
        _=mouse.update(ControllerState(),enabled:true,precise:precise,nowMillis:750)
        return mouse
    }

    @Test func holdingStartFor750MsSwitchesItOnAndOff() {
        var mouse=ControllerMouse()
        _=mouse.update(ControllerState(buttons:start),enabled:true,precise:false,nowMillis:0)
        #expect(mouse.update(ControllerState(),enabled:true,precise:false,nowMillis:749).switched == nil)
        #expect(!mouse.active)
        _=mouse.update(ControllerState(buttons:start),enabled:true,precise:false,nowMillis:1000)
        #expect(mouse.update(ControllerState(),enabled:true,precise:false,nowMillis:1750).switched == true)
        #expect(mouse.active)
        _=mouse.update(ControllerState(buttons:start),enabled:true,precise:false,nowMillis:2000)
        #expect(mouse.update(ControllerState(),enabled:true,precise:false,nowMillis:2750).switched == false)
        #expect(!mouse.active)
    }

    @Test func faceButtonsClickAndTheDpadScrollsAClick() {
        var mouse=activeMouse()
        #expect(mouse.update(ControllerState(buttons:a),enabled:true,precise:false,nowMillis:800).events == [.button(number:1,down:true)])
        #expect(mouse.update(ControllerState(buttons:b),enabled:true,precise:false,nowMillis:810).events == [.button(number:1,down:false),.button(number:3,down:true)])
        #expect(mouse.update(ControllerState(buttons:b | 0x1),enabled:true,precise:false,nowMillis:820).events == [.scroll(vertical:120,horizontal:0)])
        #expect(mouse.update(ControllerState(buttons:b | 0x1 | 0x4),enabled:true,precise:false,nowMillis:830).events == [.scroll(vertical:0,horizontal:-120)])
        #expect(mouse.release() == [.button(number:3,down:false)],"a quit lets go of the held click")
    }

    @Test func turningTheSettingOffSwitchesItOff() {
        var mouse=activeMouse()
        _=mouse.update(ControllerState(buttons:a),enabled:true,precise:false,nowMillis:800)
        let off=mouse.update(ControllerState(buttons:a),enabled:false,precise:false,nowMillis:900)
        #expect(off.switched == false)
        #expect(off.events == [.button(number:1,down:false)])
        #expect(!mouse.active)
    }

    @Test func theSticksMoveAndScrollEvery50Ms() {
        var mouse=activeMouse()
        let held=ControllerState(leftX:32767,leftY:0,rightX:0,rightY:32767)
        _=mouse.update(held,enabled:true,precise:false,nowMillis:800)
        #expect(mouse.tick(held,scrollStick:.right,precise:false,nowMillis:1000) == [.motion(dx:64,dy:0),.scroll(vertical:64,horizontal:0)])
        #expect(mouse.tick(held,scrollStick:.right,precise:false,nowMillis:1049) == [],"no faster than every 50 ms")
        let up=ControllerState(leftX:0,leftY:32767)
        #expect(mouse.tick(up,scrollStick:.off,precise:false,nowMillis:1050) == [.motion(dx:0,dy:-64)],"stick up moves the pointer up")
        #expect(ControllerMouse.movement(16383,0).0 == 8,"small deflections stay fine")
        #expect(ControllerMouse().tick(held,scrollStick:.right,precise:false,nowMillis:0) == [],"off: nothing")
    }

    @Test func thePreciseMouseMovesInDoublingFixedSteps() {
        var mouse=activeMouse(precise:true)
        _=mouse.update(ControllerState(buttons:y),enabled:true,precise:true,nowMillis:800)
        let held=ControllerState(buttons:x,leftX:32767,leftY:0)
        _=mouse.update(held,enabled:true,precise:true,nowMillis:810)
        #expect(mouse.tick(held,scrollStick:.right,precise:true,nowMillis:1000) == [.motion(dx:2,dy:0)])
    }

    @Test func theLeaveComboNeedsExactlyItsButtonsOnAPress() {
        let combo=ControllerLeaveCombo.startSelectLbRb
        #expect(combo.mask == 0x10 | 0x20 | 0x100 | 0x200)
        #expect(combo.completed(physical:combo.mask,previous:0x10 | 0x20 | 0x100))
        #expect(!combo.completed(physical:combo.mask,previous:combo.mask),"a stick move while held is no new press")
        #expect(!combo.completed(physical:combo.mask | 0x1000,previous:combo.mask),"another button too is not the combo")
        #expect(ControllerLeaveCombo.lbRbAB.mask == 0x100 | 0x200 | 0x1000 | 0x2000)
    }

    @Test func olderSettingsKeepNightjarsDefaults() throws {
        let old=try JSONDecoder().decode(InputPreferences.self,from:Data(#"{"controllers":true}"#.utf8))
        #expect(old.controllerMouse && old.scrollStick == .right && !old.preciseControllerMouse && old.leaveCombo == .startSelectLbRb)
        let unknown=try JSONDecoder().decode(InputPreferences.self,from:Data(#"{"leaveCombo":"guide","scrollStick":"both"}"#.utf8))
        #expect(unknown.leaveCombo == .startSelectLbRb && unknown.scrollStick == .right)
        var chosen=InputPreferences();chosen.leaveCombo = .lbRbXY;chosen.controllerMouse=false
        let back=try JSONDecoder().decode(InputPreferences.self,from:JSONEncoder().encode(chosen))
        #expect(back.leaveCombo == .lbRbXY && !back.controllerMouse)
    }
}
