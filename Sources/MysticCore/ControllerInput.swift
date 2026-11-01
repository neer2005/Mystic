/// A complete Moonlight controller state. Positive Y points up on both APIs.
public struct ControllerState: Sendable, Equatable {
    public var buttons: UInt32
    public var leftTrigger: UInt8, rightTrigger: UInt8
    public var leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16
    public init(buttons: UInt32 = 0, leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0,
                leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0) {
        self.buttons=buttons;self.leftTrigger=leftTrigger;self.rightTrigger=rightTrigger
        self.leftX=leftX;self.leftY=leftY;self.rightX=rightX;self.rightY=rightY
    }
    public static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 };return UInt8((min(1,max(0,value))*255).rounded())
    }
    /// Radial dead zone, rescaled to preserve full travel; clamps invalid device input.
    public static func stick(x: Float,y: Float,deadZone: Double = 0.12) -> (Int16,Int16) {
        guard x.isFinite,y.isFinite else { return (0,0) }
        let x=Double(min(1,max(-1,x))),y=Double(min(1,max(-1,y)))
        let magnitude=(x*x+y*y).squareRoot()
        guard magnitude > deadZone else { return (0,0) }
        let scale=(min(1,magnitude)-deadZone)/(1-deadZone)/magnitude
        func axis(_ value: Double) -> Int16 { Int16((value * (value < 0 ? 32768 : 32767)).rounded()) }
        return (axis(x*scale),axis(y*scale))
    }
}

/// Moonlight controller-arrival capability bits implemented by Mystic. Touchpad bits are
/// absent: GameController gives no reliable finger-down state, so no contacts are sent.
public struct ControllerCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue=rawValue }
    public static let analogTriggers=Self(rawValue:0x01)
    public static let rumble=Self(rawValue:0x02)
    public static let triggerRumble=Self(rawValue:0x04)
    public static let accelerometer=Self(rawValue:0x10)
    public static let gyroscope=Self(rawValue:0x20)
    public static let battery=Self(rawValue:0x40)
    public static let light=Self(rawValue:0x80)
}

/// The arrival's controller type, which picks the host's emulated pad.
public enum ControllerKind: UInt8, Sendable {
    case unknown=0, xbox=1, playStation=2, nintendo=3
}

/// Moonlight button flags (`LI_*_FLAG`).
public enum ControllerButtons {
    public static let guide: UInt32=0x400
    public static let paddles: [UInt32]=[0x01_0000,0x02_0000,0x04_0000,0x08_0000]
    public static let touchpad: UInt32=0x10_0000
    public static let misc: UInt32=0x20_0000
    /// D-pad, Start/Back, stick clicks, shoulders and face buttons: every extended gamepad.
    public static let classic: UInt32=0xF3FF
    /// Nightjar's Nintendo button layout: A with B, X with Y.
    public static func swappingFace(_ buttons: UInt32) -> UInt32 {
        let a=buttons & 0x1000,b=buttons & 0x2000,x=buttons & 0x4000,y=buttons & 0x8000
        return (buttons & ~UInt32(0xF000)) | a << 1 | b >> 1 | x << 1 | y >> 1
    }
}

/// Moonlight's motion sensor types (`LI_MOTION_TYPE_*`).
public enum ControllerMotionKind: UInt8, Sendable {
    case accelerometer=1, gyroscope=2
}

/// A battery report in Moonlight's terms (`LI_BATTERY_STATE_*`, percent 255 when unknown).
public struct ControllerBattery: Sendable, Equatable {
    public enum State: UInt8, Sendable { case unknown=0, notPresent=1, discharging=2, charging=3, full=5 }
    public let state: State
    public let percent: UInt8
    public init(state: State,percent: UInt8) { self.state=state;self.percent=percent }
    /// `level` is 0...1; anything else is an unknown percentage.
    public init(state: State,level: Float) {
        self.state=state
        percent = level.isFinite && (0...1).contains(level) ? UInt8((level*100).rounded()) : 0xFF
    }
}

/// An owned snapshot of the host's latest request for one controller output: motor
/// amplitudes, the light colour (`first` red << 8 | green, `second` blue), or a motion
/// sensor's report rate in Hz (`first`; zero stops it).
public struct ControllerFeedback: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case rumble=1, triggerRumble=2, light=3, accelerometerRate=4, gyroscopeRate=5 }
    public let slot: UInt8
    public let kind: Kind
    public let first: UInt16
    public let second: UInt16
    public let epoch: UInt64
    public init(slot: UInt8,kind: Kind,first: UInt16,second: UInt16,epoch: UInt64 = 0) {
        self.slot=slot;self.kind=kind;self.first=first;self.second=second;self.epoch=epoch
    }
}
