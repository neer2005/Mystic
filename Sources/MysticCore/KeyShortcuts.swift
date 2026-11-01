public import Foundation

/// Saved key chords sent to the host from the Stream menu, for keys macOS keeps for itself
/// (Command–Tab, Control–Option–Delete) or that a Mac keyboard lacks. Nightjar's desktop
/// `shortcuts.rs`, whose file is Android's: `{"version":1,"data":[{"id","name","keys"}]}` with
/// portable key names such as `WIN` and `TAB`, so a file moves between Mystic, Nightjar and
/// Android unchanged.
public struct KeyShortcuts: Codable, Sendable, Equatable {
    public struct Shortcut: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public var name: String
        public var keys: [String]
        /// The keys as typed in Settings: `CTRL + ALT + DELETE`.
        public var chord: String { keys.joined(separator:" + ") }
    }
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description=description }
    }
    public static let maxBytes=64*1024
    public static let maxShortcuts=32
    private var version=1
    public private(set) var data: [Shortcut]=[]
    public init() {}

    /// A file or saved document; anything invalid refuses all of it.
    public static func parse(_ json: Data) throws -> Self {
        guard json.count <= maxBytes else { throw Failure("Shortcut file is larger than 64 KiB.") }
        struct File: Decodable { let version: Int?;let data: [Shortcut] }
        let file: File
        do { file=try JSONDecoder().decode(File.self,from:json) } catch { throw Failure("Invalid shortcut file.") }
        guard (file.version ?? 1) == 1 else { throw Failure("Unsupported shortcut file version.") }
        guard file.data.count <= maxShortcuts else { throw Failure("You can save up to 32 shortcuts.") }
        var shortcuts=Self(),ids=Set<String>()
        for entry in file.data {
            guard (1...64).contains(entry.id.utf8.count),
                  entry.id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }),
                  ids.insert(entry.id).inserted else { throw Failure("Invalid or repeated shortcut ID.") }
            shortcuts.data.append(Shortcut(id:entry.id,name:try name(entry.name),keys:try normalized(entry.keys)))
        }
        return shortcuts
    }
    public func encoded() -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
    /// Saves a new shortcut, or replaces the one with `id`; an invalid chord changes nothing.
    public mutating func save(id: String? = nil,name: String,chord: String) throws {
        let name=try Self.name(name)
        guard chord.utf8.count <= 256 else { throw Failure("Use a chord of at most 256 characters.") }
        let keys=try Self.normalized(chord.split(separator:"+",omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:.whitespaces) })
        if let id {
            guard let index=data.firstIndex(where: { $0.id == id }) else { throw Failure("Shortcut no longer exists.") }
            data[index].name=name;data[index].keys=keys
        } else {
            guard data.count < Self.maxShortcuts else { throw Failure("You can save up to 32 shortcuts.") }
            let id=(1...).lazy.map { "mac-\($0)" }.first { id in !data.contains { $0.id == id } }!
            data.append(Shortcut(id:id,name:name,keys:keys))
        }
    }
    public mutating func remove(id: String) { data.removeAll { $0.id == id } }

    private static func name(_ name: String) throws -> String {
        let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty,name.count <= 80,!name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw Failure("Use a name between 1 and 80 characters without control characters.")
        }
        return trimmed
    }
    static func normalized(_ keys: [String]) throws -> [String] {
        guard (1...8).contains(keys.count) else { throw Failure("Use between 1 and 8 keys in each chord.") }
        var seen=Set<UInt16>()
        return try keys.map { key in
            guard let code=keyCode(key) else { throw Failure("Unsupported key: \(key)") }
            guard seen.insert(code).inserted else { throw Failure("Repeated key: \(key)") }
            return keyName(code)
        }
    }

    /// The chord as key presses in order, modifiers first, then releases in reverse.
    public static func events(_ keys: [String]) -> [RemoteInputEvent] {
        let codes=keys.compactMap(keyCode).sorted { (MacKeyboard.modifierBit(for:$0) == 0 ? 1 : 0) < (MacKeyboard.modifierBit(for:$1) == 0 ? 1 : 0) }
        var pressed: [UInt16]=[],events: [RemoteInputEvent]=[]
        func modifiers(_ code: UInt16) -> UInt8 {
            pressed.reduce(0) { $0 | MacKeyboard.modifierBit(for:$1) } | (extended.contains(code) ? 0x10 : 0)
        }
        for code in codes { pressed.append(code);events.append(.key(code:0x8000 | code,down:true,modifiers:modifiers(code),flags:0)) }
        while let code=pressed.popLast() { events.append(.key(code:0x8000 | code,down:false,modifiers:modifiers(code),flags:0)) }
        return events
    }
    /// The keys Mystic's own keyboard path sends as extended (navigation, right modifiers, Windows).
    private static let extended: Set<UInt16> = [0x5B,0x5C,0xA3,0xA5,0x6F,0x2D,0x2E,0x24,0x23,0x21,0x22,0x25,0x26,0x27,0x28]

    /// Android's portable names and their Windows aliases, as Nightjar reads them.
    public static func keyCode(_ name: String) -> UInt16? {
        var name=name.trimmingCharacters(in:.whitespaces).uppercased()
        if name.hasPrefix("KEYCODE_") { name.removeFirst(8) }
        if name == "VK_MENU" { name="ALT" } else if name.hasPrefix("VK_") { name.removeFirst(3) }
        if name.utf8.count == 1,let c=name.utf8.first,(0x41...0x5A).contains(c) || (0x30...0x39).contains(c) { return UInt16(c) }
        if name.hasPrefix("F"),let n=UInt16(name.dropFirst()),(1...24).contains(n) { return 0x6F+n }
        if name.hasPrefix("NUMPAD_"),let n=UInt16(name.dropFirst(7)),n < 10 { return 0x60+n }
        return aliases[name]
    }
    static func keyName(_ code: UInt16) -> String {
        switch code {
        case 0x30...0x39,0x41...0x5A: String(UnicodeScalar(UInt8(code)))
        case 0x70...0x87: "F\(code-0x6F)"
        case 0x60...0x69: "NUMPAD_\(code-0x60)"
        default: names[code]!
        }
    }
    private static let names: [UInt16:String] = [
        0xA2:"CTRL",0xA3:"CTRL_RIGHT",0xA0:"SHIFT",0xA1:"SHIFT_RIGHT",0xA4:"ALT",0xA5:"ALT_RIGHT",0x5B:"WIN",0x5C:"META_RIGHT",
        0x1B:"ESC",0x08:"BACKSPACE",0x2E:"DELETE",0x0D:"ENTER",0x09:"TAB",0x20:"SPACE",0x0C:"CLEAR",0x24:"HOME",0x23:"END",
        0x14:"CAPS_LOCK",0x90:"NUM_LOCK",0x91:"SCROLL_LOCK",0x2C:"SYSRQ",0x2A:"PRINT",0x13:"BREAK",0x21:"PAGE_UP",0x22:"PAGE_DOWN",
        0x25:"DPAD_LEFT",0x27:"DPAD_RIGHT",0x26:"DPAD_UP",0x28:"DPAD_DOWN",0x2D:"INSERT",0x5D:"MENU",0x6A:"NUMPAD_MULTIPLY",
        0x6B:"NUMPAD_ADD",0x6C:"NUMPAD_COMMA",0x6D:"NUMPAD_SUBTRACT",0x6E:"NUMPAD_DOT",0x6F:"NUMPAD_DIVIDE",0xBA:"SEMICOLON",
        0xBB:"EQUALS",0xBC:"COMMA",0xBD:"MINUS",0xBE:"PERIOD",0xBF:"SLASH",0xC0:"GRAVE",0xDB:"LEFT_BRACKET",0xDC:"BACKSLASH",
        0xDD:"RIGHT_BRACKET",0xDE:"APOSTROPHE",
    ]
    private static let aliases: [String:UInt16] = {
        var table: [String:UInt16]=[:]
        for (code,name) in names { table[name]=code }
        for (name,code): (String,UInt16) in [
            ("CONTROL",0xA2),("LCONTROL",0xA2),("CTRL_LEFT",0xA2),("RCONTROL",0xA3),("LSHIFT",0xA0),("SHIFT_LEFT",0xA0),
            ("RSHIFT",0xA1),("LMENU",0xA4),("ALT_LEFT",0xA4),("RMENU",0xA5),("LWIN",0x5B),("META_LEFT",0x5B),("RWIN",0x5C),
            ("ESCAPE",0x1B),("BACK",0x08),("DEL",0x08),("FORWARD_DEL",0x2E),("RETURN",0x0D),("NUMPAD_ENTER",0x0D),
            ("MOVE_HOME",0x24),("MOVE_END",0x23),("CAPITAL",0x14),("NUMLOCK",0x90),("SCROLL",0x91),("SNAPSHOT",0x2C),
            ("PRINTSCREEN",0x2C),("SCREENSHOT",0x2C),("PAUSE",0x13),("PRIOR",0x21),("NEXT",0x22),("LEFT",0x25),("RIGHT",0x27),
            ("UP",0x26),("DOWN",0x28),("PLUS",0xBB),("NUMPAD_EQUALS",0xBB),
        ] { table[name]=code }
        return table
    }()
}
