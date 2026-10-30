import XCTest
import AppKit
import MysticKit
@testable import MysticDesktop

@MainActor
final class ClipboardTests: XCTestCase {
    func testDisabledSyncDoesNotReadClipboardAndManualSendPreservesUnicode() async throws {
        let host=ClipboardHost(),board=TestPasteboard("héllo\n世界"),steps=ClipboardSteps()
        var busy=false
        let clipboard=make(host,board,steps,sync:false,report:{ _,value in busy=value })
        clipboard.start();await clipboard.poll()
        XCTAssertEqual(board.reads,0);let requests=await steps.requests;XCTAssertTrue(requests.isEmpty)
        clipboard.sendTextToHost()
        try await wait { host.sent.count == 1 && !busy }
        XCTAssertEqual(host.sent,["héllo\n世界"])
        clipboard.stop()
    }
    func testManualCopyCannotOverwriteNewerClipboardOrApplyAfterFocusLossOrStop() async throws {
        for scenario in 0..<3 {
            let host=ClipboardHost(holdRead:true),board=TestPasteboard("original"),steps=ClipboardSteps()
            let clipboard=make(host,board,steps,sync:false)
            clipboard.copyTextFromHost();try await wait { host.reads == 1 }
            if scenario == 0 { board.copy("new local") }
            if scenario == 1 { clipboard.invalidateFocus() }
            if scenario == 2 { clipboard.stop() }
            await host.readGate.release()
            try await Task.sleep(for:.milliseconds(20))
            XCTAssertEqual(board.value,scenario == 0 ? "new local" : "original")
            XCTAssertEqual(board.writes,0)
            clipboard.stop()
        }
    }
    func testManualReadSucceedsAndDirectionPermissionsAreIndependent() async throws {
        let host=ClipboardHost(),board=TestPasteboard("old"),steps=ClipboardSteps()
        let clipboard=make(host,board,steps,sync:false,canRead:true,canSend:false)
        clipboard.sendTextToHost();XCTAssertTrue(host.sent.isEmpty)
        clipboard.copyTextFromHost();try await wait { board.writes == 1 }
        XCTAssertEqual(board.value,"from host 🌙")
        clipboard.stop()
    }
    func testAutomaticSyncBaselinesOnStartAndFocusReturnAndReadsNothingInBackground() async throws {
        let host=ClipboardHost(),board=TestPasteboard("before stream"),steps=ClipboardSteps()
        var active=false
        let clipboard=make(host,board,steps,active:{ active })
        await clipboard.poll();XCTAssertEqual(board.reads,0)
        active=true;await clipboard.poll()
        var requests=await steps.requests
        XCTAssertEqual(requests.last?.text,"before stream");XCTAssertEqual(requests.last?.baseline,true)
        board.copy("new foreground copy");await clipboard.poll()
        requests=await steps.requests;XCTAssertEqual(requests.last?.text,"new foreground copy");XCTAssertEqual(requests.last?.baseline,false)
        active=false;clipboard.invalidateFocus();let reads=board.reads
        board.copy("copied in another app");await clipboard.poll();XCTAssertEqual(board.reads,reads)
        active=true;await clipboard.poll()
        requests=await steps.requests;XCTAssertEqual(requests.last?.text,"copied in another app");XCTAssertEqual(requests.last?.baseline,true)
        clipboard.stop()
    }
    func testHostTextIsAppliedButFilesAndImagesArePreserved() async throws {
        let host=ClipboardHost(),board=TestPasteboard("local"),steps=ClipboardSteps()
        let clipboard=make(host,board,steps)
        await clipboard.poll()
        await steps.remote("host copy");await clipboard.poll()
        XCTAssertEqual(board.value,"host copy");XCTAssertEqual(board.writes,1)
        await steps.remote("next host copy");await clipboard.poll()
        let ownWrite=await steps.requests.last;XCTAssertNil(ownWrite?.text)
        XCTAssertEqual(board.value,"next host copy");XCTAssertEqual(board.writes,2)
        board.copy("file path");board.protected=true
        await steps.remote("must not replace files");await clipboard.poll()
        XCTAssertEqual(board.value,"file path");XCTAssertEqual(board.writes,2)
        clipboard.stop()
    }
    func testNewLocalCopyDuringSyncRequestWins() async throws {
        let host=ClipboardHost(),board=TestPasteboard("initial"),steps=ClipboardSteps()
        let clipboard=make(host,board,steps)
        await clipboard.poll()
        let gate=ClipboardGate();await steps.holdNext(gate);await steps.remote("stale host")
        let poll=Task { await clipboard.poll() }
        for _ in 0..<200 { if await steps.requests.count >= 3 { break };try await Task.sleep(for:.milliseconds(2)) }
        board.copy("new local")
        await gate.release();await poll.value
        XCTAssertEqual(board.value,"new local");XCTAssertEqual(board.writes,0)
        await clipboard.poll()
        let last=await steps.requests.last;XCTAssertEqual(last?.text,"new local")
        clipboard.stop()
    }
    func testOversizedAutomaticCopyCanStillBeSentManuallyAndUnsupportedSyncDoesNotRead() async throws {
        let host=ClipboardHost(),board=TestPasteboard(String(repeating:"x",count:ClipboardText.syncLimit+1)),steps=ClipboardSteps()
        let clipboard=make(host,board,steps)
        await clipboard.poll();let requests=await steps.requests
        XCTAssertNil(requests.last?.text)
        await steps.remote("must not replace oversized local copy");await clipboard.poll()
        XCTAssertEqual(board.writes,0)
        clipboard.sendTextToHost();try await wait { host.sent.count == 1 }
        clipboard.stop()
        let unsupported=ClipboardSteps(available:false),other=TestPasteboard("keep local")
        let second=make(host,other,unsupported)
        await second.poll();await second.poll();XCTAssertEqual(other.reads,0)
        second.stop()
    }
    func testForegroundChangeDuringSyncResponseForcesABaselineInsteadOfApplying() async throws {
        let host=ClipboardHost(),board=TestPasteboard("initial"),steps=ClipboardSteps()
        let clipboard=make(host,board,steps)
        await clipboard.poll()
        let gate=ClipboardGate();await steps.holdNext(gate);await steps.remote("stale host")
        let poll=Task { await clipboard.poll() }
        for _ in 0..<200 { if await steps.requests.count >= 3 { break };try await Task.sleep(for:.milliseconds(2)) }
        clipboard.invalidateFocus()
        await gate.release();await poll.value
        XCTAssertEqual(board.value,"initial");XCTAssertEqual(board.writes,0)
        await clipboard.poll();let request=await steps.requests.last;XCTAssertEqual(request?.baseline,true)
        clipboard.stop()
    }
    func testRealPrivatePasteboardHandlesUnicodeAndProtectsNonTextAndConcealedItems() throws {
        let privateBoard=NSPasteboard.withUniqueName();defer { privateBoard.releaseGlobally() }
        let board=MacStreamPasteboard(privateBoard)
        try board.write("emoji 🌙 and accents é\nsecond line")
        XCTAssertEqual(try board.text(limit:ClipboardText.manualLimit),"emoji 🌙 and accents é\nsecond line")
        for type in [NSPasteboard.PasteboardType.fileURL,.png,.init("org.nspasteboard.ConcealedType")] {
            let item=NSPasteboardItem();item.setString("plain fallback",forType:.string);item.setData(Data([1]),forType:type)
            privateBoard.clearContents();XCTAssertTrue(privateBoard.writeObjects([item]))
            XCTAssertTrue(board.protectsContent);XCTAssertNil(try board.text(limit:ClipboardText.manualLimit))
        }
        let document=NSPasteboardItem();document.setData(Data([1]),forType:.pdf)
        privateBoard.clearContents();XCTAssertTrue(privateBoard.writeObjects([document]))
        XCTAssertTrue(board.protectsContent);XCTAssertNil(try board.text(limit:ClipboardText.manualLimit))
    }
    private func make(_ host:ClipboardHost,_ board:TestPasteboard,_ steps:ClipboardSteps,sync:Bool = true,
                      canRead:Bool = true,canSend:Bool = true,active:@escaping ()->Bool = { true },
                      report:@escaping (String,Bool)->Void = { _,_ in }) -> StreamClipboard {
        StreamClipboard(host:host,pasteboard:board,canRead:canRead,canSend:canSend,syncEnabled:sync,isActive:active,
            step:{ try await steps.step($0,$1,$2) },report:report,observeFocus:false)
    }
    private func wait(_ done:()->Bool) async throws {
        for _ in 0..<200 { if done() { return };try await Task.sleep(for:.milliseconds(5)) }
        XCTFail("Timed out waiting for clipboard operation")
    }
}

@MainActor
private final class TestPasteboard: StreamPasteboard {
    var value:String;var changeCount=0;var protected=false;var reads=0,writes=0
    init(_ value:String) { self.value=value }
    var protectsContent:Bool { protected }
    func text(limit:Int) throws -> String? { reads+=1;guard !protected else { return nil };try ClipboardText.validate(value,limit:limit);return value }
    func write(_ text:String) throws { value=text;changeCount+=1;writes+=1 }
    func copy(_ text:String) { value=text;changeCount+=1 }
}
private actor ClipboardGate {
    private var open=false
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async { if open { return };await withCheckedContinuation { continuation=$0 } }
    func release() { open=true;continuation?.resume();continuation=nil }
}
private actor ClipboardSteps {
    struct Request:Sendable { let active:Bool;let baseline:Bool;let text:String? }
    private(set) var requests:[Request]=[]
    private var incoming:String?
    private var gate:ClipboardGate?
    let available:Bool
    init(available:Bool = true) { self.available=available }
    func remote(_ text:String) { incoming=text }
    func holdNext(_ gate:ClipboardGate) { self.gate=gate }
    func step(_ active:Bool,_ baseline:Bool,_ text:String?) async throws -> ClipboardSyncResult {
        requests.append(Request(active:active,baseline:baseline,text:text))
        let next=incoming;incoming=nil
        if let gate { self.gate=nil;await gate.wait() }
        return ClipboardSyncResult(available:available,text:next)
    }
}
private final class ClipboardHost: HostService,@unchecked Sendable {
    private let lock=NSLock();private var sentValues:[String]=[];private var readCount=0
    let readGate=ClipboardGate(),holdRead:Bool
    init(holdRead:Bool = false) { self.holdRead=holdRead }
    var sent:[String] { lock.withLock { sentValues } }
    var reads:Int { lock.withLock { readCount } }
    func clipboardText() async throws -> String { lock.withLock { readCount+=1 };if holdRead { await readGate.wait() };return "from host 🌙" }
    func sendClipboardText(_ text:String) async throws { lock.withLock { sentValues.append(text) } }
    func serverInfo() async throws -> HostInfo { throw HostConnectionError("unused") }
    func pair(pin:String) async throws -> PairedHost { throw HostConnectionError("unused") }
    func apps() async throws -> [HostApp] { [] }
    func launch(_ options:LaunchOptions) async throws -> LaunchedStream { throw HostConnectionError("unused") }
    func cancel() {}
}
