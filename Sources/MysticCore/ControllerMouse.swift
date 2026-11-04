/// Nightjar's controller mouse mode (`controller_mouse.rs`, from Moonlight V+ PC): hold Start for
/// 750 ms and let go to move the PC's pointer with the controller. A and B click, the D-pad
/// scrolls a click at a time, one stick moves the pointer and the other scrolls (or both move it),
/// and with the precise mouse X moves in fixed steps that Y doubles from 1 to 128 pixels. While it
/// is on, the PC's controller sees nothing pressed. No clock or I/O: times are milliseconds.
public struct ControllerMouse: Sendable, Equatable {
    /// Which stick scrolls; the other moves the pointer. Off lets both move it.
    public enum ScrollStick: String, Codable, CaseIterable, Sendable {
        case right,left,off
        public var label: String { switch self { case .right: "Right Stick";case .left: "Left Stick";case .off: "Off" } }
    }
    /// How long Start is held to switch the mouse on or off.
    public static let holdMillis: UInt64=750
    /// Time between two pointer moves from the sticks.
    public static let tickMillis: UInt64=50
    /// One scroll click, in the host's 1/120 units.
    public static let click: Int16=120

    public private(set) var active=false
    private var startedAt: UInt64?
    private var lastTick: UInt64?
    private var buttons: UInt32=0
    private var step: UInt8=0
    public init() {}

    private static let start: UInt32=0x10,a: UInt32=0x1000,b: UInt32=0x2000,x: UInt32=0x4000,y: UInt32=0x8000
    private static let up: UInt32=0x1,down: UInt32=0x2,left: UInt32=0x4,right: UInt32=0x8

    /// Lets go of the clicks it holds and forgets a Start press, for a quit or a lost controller.
    public mutating func release() -> [RemoteInputEvent] {
        var events: [RemoteInputEvent]=[]
        if buttons & Self.a != 0 { events.append(.button(number:1,down:false)) }
        if buttons & Self.b != 0 { events.append(.button(number:3,down:false)) }
        buttons=0;startedAt=nil;lastTick=nil
        return events
    }

    /// A new controller state: the mouse events it makes, and whether the mouse switched on
    /// (true) or off (false). `enabled` is the setting: turning it off switches the mouse off.
    public mutating func update(_ state: ControllerState,enabled: Bool,precise: Bool,nowMillis: UInt64) -> (events: [RemoteInputEvent],switched: Bool?) {
        var events: [RemoteInputEvent]=[]
        var switched: Bool?
        if enabled {
            if state.buttons & Self.start != 0 {
                if startedAt == nil { startedAt=nowMillis }
            } else if let at=startedAt {
                startedAt=nil
                if nowMillis >= at+Self.holdMillis {
                    events += release()
                    active.toggle();switched=active
                }
            }
        } else if active {
            events += release()
            active=false;switched=false
        }
        guard active else { return (events,switched) }
        let pressed=state.buttons & ~buttons,released=buttons & ~state.buttons
        for (flag,number) in [(Self.a,UInt8(1)),(Self.b,UInt8(3))] where (pressed | released) & flag != 0 {
            events.append(.button(number:number,down:pressed & flag != 0))
        }
        if precise,pressed & Self.y != 0 { step = step >= 128 ? 1 : max(1,step)*2 }
        if pressed & Self.up != 0 { events.append(.scroll(vertical:Self.click,horizontal:0)) }
        if pressed & Self.down != 0 { events.append(.scroll(vertical:-Self.click,horizontal:0)) }
        if pressed & Self.left != 0 { events.append(.scroll(vertical:0,horizontal:-Self.click)) }
        if pressed & Self.right != 0 { events.append(.scroll(vertical:0,horizontal:Self.click)) }
        buttons=state.buttons
        return (events,switched)
    }

    /// Nightjar's stick curve: cubic, so small deflections stay fine; full deflection is 64 pixels a tick.
    static func movement(_ x: Int16,_ y: Int16) -> (Int16,Int16) {
        let fx=Float(x)*4/32766,fy=Float(y)*4/32766
        let speed=fx*fx+fy*fy
        return (Int16(clamping:Int(fx*speed)),Int16(clamping:Int(fy*speed)))
    }

    /// Every `tickMillis` while on: the pointer and scroll from the sticks. Stick Y is positive up.
    public mutating func tick(_ state: ControllerState,scrollStick: ScrollStick,precise: Bool,nowMillis: UInt64) -> [RemoteInputEvent] {
        guard active,!(lastTick.map { nowMillis < $0+Self.tickMillis } ?? false) else { return [] }
        lastTick=nowMillis
        let left=(state.leftX,state.leftY),right=(state.rightX,state.rightY)
        let pointer: (Int16,Int16),scroll: (Int16,Int16)?
        switch scrollStick {
        case .right: pointer=left;scroll=right
        case .left: pointer=right;scroll=left
        case .off: pointer=left;scroll=nil
        }
        let fixed: Int16=precise && buttons & Self.x != 0 ? Int16(max(1,step)) : 0
        var events: [RemoteInputEvent]=[]
        for stick in [pointer]+(scrollStick == .off ? [right] : []) {
            var (dx,dy)=Self.movement(stick.0,stick.1)
            if fixed != 0 { dx=dx.signum()*fixed;dy=dy.signum()*fixed }
            if dx != 0 || dy != 0 { events.append(.motion(dx:dx,dy:-dy)) }
        }
        if let scroll {
            let (h,v)=Self.movement(scroll.0,scroll.1)
            if h != 0 || v != 0 { events.append(.scroll(vertical:v,horizontal:h)) }
        }
        return events
    }
}

/// Nightjar's "Buttons to leave the stream" (`GamepadQuitCombo`): held together, and nothing else,
/// they leave the stream. Face buttons are positions (A is south), so the Nintendo layout leaves
/// them where they are; the mask is in Moonlight button flags.
public enum ControllerLeaveCombo: String, Codable, CaseIterable, Sendable {
    case startSelectLbRb,selectLbRbY,startLbRbA,startLbRbB,lbRbXY,lbRbAB
    public var label: String {
        switch self {
        case .startSelectLbRb: "Start + Select + LB + RB"
        case .selectLbRbY: "Select + LB + RB + Y"
        case .startLbRbA: "Start + LB + RB + A"
        case .startLbRbB: "Start + LB + RB + B"
        case .lbRbXY: "LB + RB + X + Y"
        case .lbRbAB: "LB + RB + A + B"
        }
    }
    public var mask: UInt32 {
        let shoulders: UInt32=0x100 | 0x200
        switch self {
        case .startSelectLbRb: return shoulders | 0x10 | 0x20
        case .selectLbRbY: return shoulders | 0x20 | 0x8000
        case .startLbRbA: return shoulders | 0x10 | 0x1000
        case .startLbRbB: return shoulders | 0x10 | 0x2000
        case .lbRbXY: return shoulders | 0x4000 | 0x8000
        case .lbRbAB: return shoulders | 0x1000 | 0x2000
        }
    }
    /// A press that completes the combo: `physical` held now, `previous` before this change.
    public func completed(physical: UInt32,previous: UInt32) -> Bool {
        physical & ~previous != 0 && physical == mask
    }
}

/// Nightjar's Guide hold (`gamepad.rs`): held alone for the chosen time, Guide is Mystic's and
/// never reaches the PC; Mystic gives the Mac its mouse and keyboard back there, its stand-in for
/// Nightjar's stream menu. The press is kept from the PC until it is known to be short (then the
/// PC gets a whole tap of `tapMillis`), part of a chord (then it goes through at once), or long.
public struct GuideHold: Sendable, Equatable {
    /// Nightjar's choices (`GUIDE_HOLD_MS`), 0 for off.
    public static let choices: [Int]=[0,500,1000,1500,2000]
    /// How long the PC sees a short press held (moonlight-android's minimum is 25 ms).
    public static let tapMillis: UInt64=50
    static let guide: UInt32=0x400
    enum Phase: Sendable, Equatable { case up,held(UInt64),tapped(UInt64),passed,opened }
    private(set) var phase=Phase.up
    private var guideDown=false
    public init() {}

    /// A press waits on `tick`, so it should run often until it settles.
    public var waiting: Bool { switch phase { case .held,.tapped: true;default: false } }

    /// A new state of the pad's buttons, `holdMillis` the setting (0 off).
    public mutating func observe(_ buttons: UInt32,holdMillis: Int,nowMillis: UInt64) {
        let down=buttons & Self.guide != 0,others=buttons & ~Self.guide
        defer { guideDown=down }
        guard holdMillis > 0 else { phase = .up;return }
        if down,!guideDown {
            // A tap still going out ends here; Guide joining held buttons is a chord.
            phase = others != 0 ? .passed : .held(nowMillis)
        } else if !down,guideDown {
            switch phase {
            case .held: phase = .tapped(nowMillis)
            case .tapped: break
            default: phase = .up
            }
        } else if down,others != 0,case .held=phase {
            // Another button while Guide is held: a chord for the PC (Steam's), Guide with it.
            phase = .passed
        }
    }
    /// The buttons the PC gets: Guide held back while it may still be Mystic's, a short press
    /// sent whole after its release.
    public func output(_ buttons: UInt32) -> UInt32 {
        switch phase {
        case .held,.opened: buttons & ~Self.guide
        case .tapped: buttons | Self.guide
        case .up,.passed: buttons
        }
    }
    /// On a timer while `waiting`: `opened` when the hold is long enough, `resend` when the tap's
    /// release is due and the pad's state should go out again.
    public mutating func tick(holdMillis: Int,nowMillis: UInt64) -> (opened: Bool,resend: Bool) {
        switch phase {
        case .held(let at) where holdMillis > 0 && nowMillis >= at+UInt64(holdMillis):
            phase = .opened;return (true,false)
        case .tapped(let at) where nowMillis >= at+Self.tapMillis:
            phase = guideDown ? .passed : .up;return (false,true)
        default: return (false,false)
        }
    }
}
