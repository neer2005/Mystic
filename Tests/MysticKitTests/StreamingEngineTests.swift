import Testing
@testable import MysticKit

/// These tests run the real C ABI against the real engine library. They need
/// `engine/target/release/libmystic_ffi.a`, built by `engine/scripts/test-c-abi.sh`.
@Suite("Streaming engine")
struct StreamingEngineTests {

    @Test("the linked library matches the ABI this Swift layer was written for")
    func abiMatches() throws {
        let engine = try StreamingEngine()
        _ = engine // constructing at all is the assertion: init throws on a mismatch
    }

    @Test("an engine can be created and released without touching a session")
    func lifecycle() throws {
        var engine: StreamingEngine? = try StreamingEngine()
        #expect(engine != nil)
        engine = nil // deinit stops and frees the handle
    }

    @Test("input is refused before a session starts")
    func inputBeforeStart() throws {
        let engine = try StreamingEngine()
        #expect(!engine.microphoneAvailable)
        #expect(throws: EngineError.notStarted) {
            try [UInt8(1)].withUnsafeBytes { try engine.sendMicrophone($0) }
        }

        #expect(throws: EngineError.notStarted) {
            try engine.mouseMove(dx: 1, dy: 1)
        }
        #expect(throws: EngineError.notStarted) {
            try engine.keyboard(keyCode: 0x41, down: true, modifiers: 0, flags: 0)
        }
        #expect(throws: EngineError.notStarted) {
            try engine.requestIDR()
        }
        #expect(throws: EngineError.notStarted) {
            try engine.scroll(clicks: 1)
        }
        #expect(throws: EngineError.notStarted) {
            try engine.controllerArrival(slot:0,activeMask:1)
        }
        #expect(throws: EngineError.notStarted) {
            try engine.controller(slot:0,activeMask:1,buttons:0x1000,leftTrigger:17,rightTrigger:29,
                                  leftX:-32768,leftY:32767,rightX:-123,rightY:456)
        }
    }

    @Test("stopping when nothing started is harmless")
    func stopIsIdempotent() throws {
        let engine = try StreamingEngine()
        engine.stop()
        engine.stop()
        engine.interrupt()
    }

    @Test("a failed start names the stage that failed")
    func failedStartReportsStage() throws {
        let engine = try StreamingEngine()
        let host = "127.0.0.1"

        var caught: EngineError?
        do {
            try engine.start(host: host, appVersion: "7.1.431.-1") { _ in }
        } catch let error as EngineError {
            caught = error
        }

        guard case let .startFailed(message) = caught else {
            Issue.record("expected a startFailed error, got \(String(describing: caught))")
            return
        }
        // Nothing is listening, so the engine fails in the RTSP handshake and says so.
        #expect(message.contains("RtspHandshake") || message.contains("Connection refused"),
                "unexpected start failure: \(message)")
    }

    @Test("stage numbering matches the engine's")
    func stageMapping() {
        #expect(Stage.platformInit.rawValue == 1)
        #expect(Stage.rtspHandshake.rawValue == 4)
        #expect(Stage.inputStreamStart.rawValue == 11)
        #expect(Stage.allCases.count == 11)
    }
}
