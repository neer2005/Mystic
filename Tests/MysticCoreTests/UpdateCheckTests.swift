import Foundation
import Testing
@testable import MysticCore

/// Nightjar's `update_check.rs` tests.
@Suite("Update check")
struct UpdateCheckTests {
    @Test func onlyANewerStableReleaseIsOffered() {
        #expect(UpdateCheck.newerStable(tag:"v4.0.1",current:"4.0.0"))
        #expect(UpdateCheck.newerStable(tag:"v4.1.0",current:"4.0.9"))
        #expect(UpdateCheck.newerStable(tag:"5.0.0",current:"4.9.9"))
        #expect(UpdateCheck.newerStable(tag:"v4.0.0",current:"4.0.0-rc.3"),"the final release follows its candidates")
        #expect(!UpdateCheck.newerStable(tag:"v4.0.0",current:"4.0.0"))
        #expect(!UpdateCheck.newerStable(tag:"v3.9.9",current:"4.0.0"))
        #expect(!UpdateCheck.newerStable(tag:"v4.1.0-rc.1",current:"4.0.0"),"a pre-release tag is never offered")
        #expect(!UpdateCheck.newerStable(tag:"nightly",current:"4.0.0"))
        #expect(!UpdateCheck.newerStable(tag:"v4.1.0",current:"a local build"))
        #expect(UpdateCheck.newerStable(tag:"v4.1",current:"4.0.0"),"a two-part tag reads as .0")
        #expect(!UpdateCheck.newerStable(tag:"v4.1.0.2",current:"4.0.0"))
        #expect(UpdateCheck.newerStable(tag:"v0.10.0",current:"0.9.0"),"numbers, not text")
    }
    @Test func theAnswerIsReadAsNightjarReadsIt() throws {
        func release(_ tag: String,draft: Bool = false,pre: Bool = false) -> Data {
            Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(pre),"html_url":"https://github.com/neer2005/Mystic/releases/tag/\#(tag)"}"#.utf8)
        }
        #expect(try UpdateCheck.offer(release("v0.2.0"),current:"0.1.0")
            == UpdateCheck.Release(version:"0.2.0",page:URL(string:"https://github.com/neer2005/Mystic/releases/tag/v0.2.0")!))
        #expect(try UpdateCheck.offer(release("v0.2.0",draft:true),current:"0.1.0") == nil,"a draft")
        #expect(try UpdateCheck.offer(release("v0.2.0",pre:true),current:"0.1.0") == nil,"a pre-release")
        #expect(try UpdateCheck.offer(release("v0.1.0"),current:"0.1.0") == nil,"this version")
        #expect(throws:UpdateCheck.Failure.self) { try UpdateCheck.offer(Data(#"{"message":"Not Found"}"#.utf8),current:"0.1.0") }
        #expect(throws:UpdateCheck.Failure.self) { try UpdateCheck.offer(Data("<html>".utf8),current:"0.1.0") }
        #expect(throws:UpdateCheck.Failure.self,"only GitHub pages open") {
            try UpdateCheck.offer(Data(#"{"tag_name":"v9.0.0","html_url":"https://evil.example/"}"#.utf8),current:"0.1.0")
        }
    }
}
