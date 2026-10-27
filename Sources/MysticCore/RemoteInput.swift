public enum RemoteInputEvent: Sendable, Equatable {
    case key(code: UInt16, down: Bool, modifiers: UInt8, flags: UInt8)
    case button(number: UInt8, down: Bool)
    case position(x: Int16, y: Int16, width: Int16, height: Int16)
    case motion(dx: Int16, dy: Int16)
    case scroll(vertical: Int16, horizontal: Int16)
    /// Release the keys/buttons actually accepted by the engine, discarding unsent input.
    case releaseAll
}

public struct WindowsKey: Sendable, Equatable {
    public let virtualCode: UInt16
    public let extended: Bool
    public var wireCode: UInt16 { virtualCode | 0x8000 }
}

/// Physical macOS virtual key positions -> Windows VK. Host keyboard layout interprets them.
public enum MacKeyboard {
    public static func key(_ code: UInt16) -> WindowsKey? {
        guard let vk = codes[code] else { return nil }
        return WindowsKey(virtualCode: vk, extended: extended.contains(code))
    }
    // ANSI letters, digits, punctuation; navigation, F1-F20, keypad, ISO and JIS keys.
    private static let codes: [UInt16: UInt16] = [
        0:0x41,1:0x53,2:0x44,3:0x46,4:0x48,5:0x47,6:0x5A,7:0x58,8:0x43,9:0x56,
        10:0xE2,11:0x42,12:0x51,13:0x57,14:0x45,15:0x52,16:0x59,17:0x54,
        18:0x31,19:0x32,20:0x33,21:0x34,22:0x36,23:0x35,24:0xBB,25:0x39,
        26:0x37,27:0xBD,28:0x38,29:0x30,30:0xDD,31:0x4F,32:0x55,33:0xDB,
        34:0x49,35:0x50,36:0x0D,37:0x4C,38:0x4A,39:0xDE,40:0x4B,41:0xBA,
        42:0xDC,43:0xBC,44:0xBF,45:0x4E,46:0x4D,47:0xBE,48:0x09,49:0x20,
        50:0xC0,51:0x08,53:0x1B,54:0x5C,55:0x5B,56:0xA0,57:0x14,58:0xA4,
        59:0xA2,60:0xA1,61:0xA5,62:0xA3,64:0x80,65:0x6E,67:0x6A,69:0x6B,
        71:0x90,75:0x6F,76:0x0D,78:0x6D,79:0x81,80:0x82,81:0xBB,82:0x60,
        83:0x61,84:0x62,85:0x63,86:0x64,87:0x65,88:0x66,89:0x67,90:0x83,91:0x68,
        92:0x69,93:0xDC,94:0xE2,95:0x6C,96:0x74,97:0x75,98:0x76,99:0x72,
        100:0x77,101:0x78,102:0x1D,103:0x7A,104:0x1C,105:0x7C,106:0x7F,
        107:0x7D,109:0x79,111:0x7B,113:0x7E,114:0x2D,115:0x24,116:0x21,
        117:0x2E,118:0x73,119:0x23,120:0x71,121:0x22,122:0x70,
        123:0x25,124:0x27,125:0x28,126:0x26,
    ]
    private static let extended: Set<UInt16> = [54,55,61,62,75,76,114,115,116,117,119,121,123,124,125,126]
    /// Device-specific modifier bits from Apple's IOLLEvent.h. Used to distinguish two held Shift keys.
    public static func modifierDeviceMask(_ code: UInt16) -> UInt64? {
        switch code {
        case 59: 0x0001
        case 56: 0x0002
        case 60: 0x0004
        case 55: 0x0008
        case 54: 0x0010
        case 58: 0x0020
        case 61: 0x0040
        case 62: 0x2000
        default: nil
        }
    }
    public static func modifierBit(for code: UInt16) -> UInt8 {
        switch code & 0xFF {
        case 0xA0,0xA1: 1
        case 0xA2,0xA3: 2
        case 0xA4,0xA5: 4
        case 0x5B,0x5C: 8
        default: 0
        }
    }
}

/// A capture's logical state. Never synthesizes a key-down from a key-up received after focus changes.
public struct RemoteInputState: Sendable {
    private var keys: [UInt16: WindowsKey] = [:]
    private var buttons: Set<UInt8> = []
    private var capsLock: Bool
    public init(capsLock: Bool = false) { self.capsLock = capsLock }
    private var modifiers: UInt8 { keys.values.reduce(0) { $0 | MacKeyboard.modifierBit(for: $1.virtualCode) } }
    public mutating func key(_ physical: UInt16, down: Bool, repeatEvent: Bool = false) -> [RemoteInputEvent] {
        guard let key = MacKeyboard.key(physical), MacKeyboard.modifierDeviceMask(physical) == nil, physical != 57 else { return [] }
        if down {
            // The host performs repeat from held state. Local repeat must not re-press a released key.
            guard !repeatEvent, keys[physical] == nil else { return [] }
            keys[physical] = key
        } else { guard keys.removeValue(forKey: physical) != nil else { return [] } }
        return [.key(code:key.wireCode,down:down,modifiers:modifiers | (key.extended ? 0x10 : 0),flags:0)]
    }
    public mutating func modifier(_ physical: UInt16, rawFlags: UInt64, capsLock enabled: Bool) -> [RemoteInputEvent] {
        if physical == 57 {
            guard enabled != capsLock else { return [] }
            capsLock = enabled
            return [.key(code:0x8014,down:true,modifiers:modifiers,flags:0),.key(code:0x8014,down:false,modifiers:modifiers,flags:0)]
        }
        guard let mask = MacKeyboard.modifierDeviceMask(physical), let key = MacKeyboard.key(physical) else { return [] }
        let group: (device:UInt64,aggregate:UInt64)
        switch MacKeyboard.modifierBit(for:key.virtualCode) {
        case 1: group=(0x6,0x20000)
        case 2: group=(0x2001,0x40000)
        case 4: group=(0x60,0x80000)
        default: group=(0x18,0x100000)
        }
        // Synthesized/accessibility events may omit device-side bits. Real hardware uses exact sides.
        let down = rawFlags & group.device != 0 ? rawFlags & mask != 0 :
            (rawFlags & group.aggregate != 0 && keys[physical] == nil)
        if down { guard keys[physical] == nil else { return [] }; keys[physical] = key }
        else { guard keys.removeValue(forKey: physical) != nil else { return [] } }
        return [.key(code:key.wireCode,down:down,modifiers:modifiers | (key.extended ? 0x10 : 0),flags:0)]
    }
    /// Reconcile a key event's aggregate flags when an accessibility source omits flagsChanged events.
    public mutating func synchronizeModifiers(rawFlags: UInt64) -> [RemoteInputEvent] {
        let groups: [(UInt16,UInt16,UInt64,UInt64)] = [
            (56,60,0x6,0x20000),(59,62,0x2001,0x40000),
            (58,61,0x60,0x80000),(55,54,0x18,0x100000),
        ]
        var result: [RemoteInputEvent] = []
        for (left,right,devices,aggregate) in groups {
            if rawFlags & devices != 0 {
                result += modifier(left,rawFlags:rawFlags,capsLock:capsLock)
                result += modifier(right,rawFlags:rawFlags,capsLock:capsLock)
            } else if rawFlags & aggregate == 0 {
                result += modifier(left,rawFlags:0,capsLock:capsLock)
                result += modifier(right,rawFlags:0,capsLock:capsLock)
            } else if keys[left] == nil && keys[right] == nil {
                result += modifier(left,rawFlags:rawFlags,capsLock:capsLock)
            }
        }
        return result
    }
    public mutating func button(_ macButton: Int, down: Bool) -> [RemoteInputEvent] {
        let number: UInt8
        switch macButton { case 0: number=1;case 1: number=3;case 2: number=2;case 3: number=4;case 4: number=5;default:return [] }
        if down { guard buttons.insert(number).inserted else { return [] } }
        else { guard buttons.remove(number) != nil else { return [] } }
        return [.button(number:number,down:down)]
    }
    public mutating func releaseAll() -> RemoteInputEvent {
        keys.removeAll(keepingCapacity:true);buttons.removeAll(keepingCapacity:true)
        return .releaseAll
    }
}

public enum InputGeometry {
    /// AppKit view coordinates are bottom-up; host coordinates are top-down. Letterbox clicks are ignored.
    public static func position(x: Double,y: Double,left: Double,bottom: Double,width: Double,height: Double,clamp: Bool = false) -> RemoteInputEvent? {
        guard [x,y,left,bottom,width,height].allSatisfy(\.isFinite), width>0,height>0 else { return nil }
        let nx=(x-left)/width, ny=(y-bottom)/height
        guard clamp || (nx>=0 && nx<=1 && ny>=0 && ny<=1) else { return nil }
        return .position(x:Int16((min(1,max(0,nx))*32766).rounded()),y:Int16(((1-min(1,max(0,ny)))*32766).rounded()),width:32767,height:32767)
    }
}

/// Fractional trackpad movement survives between events; large deltas cannot overflow C's Int16.
public struct InputDelta: Sendable {
    private var x: Double = 0, y: Double = 0
    public init() {}
    public mutating func consume(x dx: Double,y dy: Double,scale: Double = 1) -> (Int16,Int16) {
        guard dx.isFinite,dy.isFinite,scale.isFinite else { return (0,0) }
        x=min(32767,max(-32768,x+dx*scale));y=min(32767,max(-32768,y+dy*scale))
        let ix=x.rounded(.towardZero),iy=y.rounded(.towardZero)
        x-=ix;y-=iy
        return (Int16(ix),Int16(iy))
    }
}

/// Bounded pending events. Coalescing never moves a position across a button/key boundary.
public struct RemoteInputQueue: Sendable {
    private var pending: [RemoteInputEvent] = []
    private let capacity: Int
    public init(capacity: Int = 256) { self.capacity=max(1,capacity) }
    public mutating func append(_ event: RemoteInputEvent) -> Bool {
        if event == .releaseAll { pending=[.releaseAll];return true }
        if let last=pending.last {
            switch (last,event) {
            case (.position,.position): pending[pending.count-1]=event;return true
            case let (.motion(ax,ay),.motion(bx,by)):
                pending[pending.count-1] = .motion(dx:Int16(clamping:Int(ax)+Int(bx)),dy:Int16(clamping:Int(ay)+Int(by)));return true
            case let (.scroll(av,ah),.scroll(bv,bh)):
                pending[pending.count-1] = .scroll(vertical:Int16(clamping:Int(av)+Int(bv)),horizontal:Int16(clamping:Int(ah)+Int(bh)));return true
            default:break
            }
        }
        guard pending.count<capacity else { pending=[.releaseAll];return false }
        pending.append(event);return true
    }
    public mutating func take() -> [RemoteInputEvent] { let result=pending;pending.removeAll(keepingCapacity:true);return result }
}

/// Tracks only events accepted by the transport. Release retries retain failed keys for another attempt.
public struct RemoteInputDelivery {
    private var keys: [UInt16: (UInt8,UInt8)] = [:]
    private var buttons: Set<UInt8> = []
    public init() {}
    public mutating func deliver(_ event: RemoteInputEvent,send: (RemoteInputEvent) throws -> Void) throws {
        if event == .releaseAll {
            var failure: (any Error)?
            let ordered=keys.keys.sorted {
                let lm=MacKeyboard.modifierBit(for:$0) != 0,rm=MacKeyboard.modifierBit(for:$1) != 0
                return lm == rm ? $0<$1 : !lm
            }
            for code in ordered {
                guard let (mods,flags)=keys[code] else { continue }
                do { try send(.key(code:code,down:false,modifiers:mods & 0x10,flags:flags));keys.removeValue(forKey:code) }
                catch { failure=error }
            }
            for number in buttons.sorted() {
                do { try send(.button(number:number,down:false));buttons.remove(number) } catch { failure=error }
            }
            if let failure { throw failure };return
        }
        try send(event)
        switch event {
        case let .key(code,down,modifiers,flags): if down { keys[code]=(modifiers,flags) } else { keys.removeValue(forKey:code) }
        case let .button(number,down): if down { buttons.insert(number) } else { buttons.remove(number) }
        default:break
        }
    }
}
