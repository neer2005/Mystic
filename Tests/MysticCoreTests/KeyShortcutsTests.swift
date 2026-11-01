import Foundation
import Testing
@testable import MysticCore

/// Nightjar's `shortcuts.rs` tests, for the same file and chords.
@Suite("Key shortcuts")
struct KeyShortcutsTests {
    private let android=Data(#"{"version":1,"data":[{"id":"desktop","name":"Task view","keys":["WIN","TAB"]}]}"#.utf8)
    @Test func androidsFileRoundTripsAndABadChordReplacesNothing() throws {
        var shortcuts=try KeyShortcuts.parse(android)
        #expect(shortcuts.data == [KeyShortcuts.Shortcut(id:"desktop",name:"Task view",keys:["WIN","TAB"])])
        #expect(try KeyShortcuts.parse(shortcuts.encoded()) == shortcuts)
        let before=shortcuts
        #expect(throws:KeyShortcuts.Failure.self) { try shortcuts.save(id:"desktop",name:"Bad",chord:"CTRL + CTRL_LEFT") }
        #expect(shortcuts == before)
        let text=String(decoding:android,as:UTF8.self)
        for broken in [text.replacingOccurrences(of:"\"TAB\"",with:"\"UNKNOWN\""),text.replacingOccurrences(of:"\"version\":1",with:"\"version\":2"),
                       #"{"data":[{"id":"a","name":"A","keys":["A"]},{"id":"a","name":"B","keys":["B"]}]}"#,
                       #"{"data":[{"id":"bad id","name":"A","keys":["A"]}]}"#,"<html>"] {
            #expect(throws:KeyShortcuts.Failure.self) { try KeyShortcuts.parse(Data(broken.utf8)) }
        }
        #expect(throws:KeyShortcuts.Failure.self) { try KeyShortcuts.parse(Data(repeating:0x20,count:KeyShortcuts.maxBytes+1)) }
        try shortcuts.save(name:"Portable aliases",chord:"VK_LCONTROL + PRINTSCREEN + F01")
        #expect(shortcuts.data[1].keys == ["CTRL","SYSRQ","F1"] && shortcuts.data[1].id == "mac-1")
        try shortcuts.save(id:"mac-1",name:"  Renamed ",chord:"ctrl+alt+delete")
        #expect(shortcuts.data[1].name == "Renamed" && shortcuts.data[1].chord == "CTRL + ALT + DELETE")
        shortcuts.remove(id:"desktop");#expect(shortcuts.data.map(\.id) == ["mac-1"])
    }
    @Test func everyKeyNameReadsBack() {
        #expect(KeyShortcuts.keyCode("KEYCODE_F24") == 0x87)
        #expect(KeyShortcuts.keyCode("VK_MENU") == 0xA4)
        #expect(KeyShortcuts.keyCode("NUMPAD_9") == 0x69)
        #expect(KeyShortcuts.keyCode("PRINT") == 0x2A && KeyShortcuts.keyCode("SCREENSHOT") == 0x2C)
        for code in Array(0x30...0x39)+Array(0x41...0x5A)+Array(0x60...0x87) {
            #expect(KeyShortcuts.keyCode(KeyShortcuts.keyName(UInt16(code))) == UInt16(code))
        }
    }
    @Test func chordsPressModifiersFirstAndReleaseInReverse() {
        let events=KeyShortcuts.events(["TAB","ALT","CTRL"])
        let expected: [(UInt16,Bool,UInt8)]=[(0xA4,true,4),(0xA2,true,6),(0x09,true,6),(0x09,false,6),(0xA2,false,4),(0xA4,false,0)]
        #expect(events == expected.map { .key(code:0x8000 | $0.0,down:$0.1,modifiers:$0.2,flags:0) })
        #expect(KeyShortcuts.events(["WIN","LEFT"]).first == .key(code:0x805B,down:true,modifiers:0x18,flags:0),"Windows is extended, as Mystic's keys send it")
    }
}
