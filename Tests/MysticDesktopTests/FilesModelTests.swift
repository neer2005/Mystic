import XCTest
import MysticKit
@testable import MysticDesktop

@MainActor
final class FilesModelTests: XCTestCase {
    private func snapshot(access: String = "known",notices: [String] = []) -> FilesSnapshot {
        let json: [String:Any]=["access":access,"mayUpload":true,"mayDownload":true,"listing":false,"active":false,"downloads":"/d","notices":notices,"transfers":[]]
        return try! JSONDecoder().decode(FilesSnapshot.self,from:JSONSerialization.data(withJSONObject:json))
    }
    func testNoticesCollectUntilCleared() {
        let page=FakePage(answer:snapshot(notices:["a was not sent"]))
        let model=FilesModel(page:page)
        model.send([URL(fileURLWithPath:"/a")])
        XCTAssertEqual(page.sent,[URL(fileURLWithPath:"/a")])
        XCTAssertEqual(model.notices,["a was not sent"])
        XCTAssertTrue(model.hasFinished)
        page.answer=snapshot()
        model.clearFinished()
        XCTAssertTrue(model.notices.isEmpty)
        XCTAssertFalse(model.hasFinished)
    }
    func testAFailedRequestSaysSoAndTheNextClearsIt() {
        let page=FakePage(answer:snapshot())
        let model=FilesModel(page:page)
        page.failure="engine gone"
        model.refresh()
        XCTAssertEqual(model.problem,"engine gone")
        page.failure=nil
        model.refresh()
        XCTAssertNil(model.problem)
    }
}
private final class FakePage: FilesPage,@unchecked Sendable {
    var answer: FilesSnapshot,failure: String?,sent: [URL]=[]
    init(answer: FilesSnapshot) { self.answer=answer }
    private func reply() throws -> FilesSnapshot { if let failure { throw HostConnectionError(failure) };return answer }
    func snapshot() throws -> FilesSnapshot { try reply() }
    func checkAgain() throws -> FilesSnapshot { try reply() }
    func refresh() throws -> FilesSnapshot { try reply() }
    func send(_ files: [URL]) throws -> FilesSnapshot { sent+=files;return try reply() }
    func download(name: String,size: UInt64) throws -> FilesSnapshot { try reply() }
    func cancel(_ id: UInt64) throws -> FilesSnapshot { try reply() }
    func retry(_ id: UInt64) throws -> FilesSnapshot { try reply() }
    func clearFinished() throws -> FilesSnapshot { try reply() }
}
