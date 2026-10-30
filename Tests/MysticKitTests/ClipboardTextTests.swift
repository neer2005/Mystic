import Testing
@testable import MysticKit

@Suite("Clipboard text bridge")
struct ClipboardTextTests {
    @Test func validatesUtf8BytesAndRejectsNulWithoutAlteringText() throws {
        try ClipboardText.validate("é",limit:2)
        #expect(throws:HostConnectionError.self) { try ClipboardText.validate("é",limit:1) }
        #expect(throws:HostConnectionError.self) { try ClipboardText.validate("a\0b",limit:100) }
        try ClipboardText.validate("",limit:0)
        #expect(throws:HostConnectionError.self) {
            try ClipboardText.validate(String(repeating:"x",count:ClipboardText.manualLimit+1),limit:ClipboardText.manualLimit)
        }
    }
    @Test func aSyncStepWithoutAStreamReturnsAStructuredError() throws {
        let engine=try StreamingEngine()
        #expect(throws:HostConnectionError.self) { try engine.clipboardStep(active:true,baseline:true,text:"local text") }
    }
}
