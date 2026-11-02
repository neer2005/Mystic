import XCTest
import MysticKit
@testable import MysticDesktop

@MainActor
final class SharedFoldersModelTests: XCTestCase {
    func testAnOperationReachesThePageAndAFailureSaysSo() throws {
        let json=#"{"path":"","loading":false,"folders":[]}"#
        let page=FakeFolders(answer:try JSONDecoder().decode(FoldersSnapshot.self,from:Data(json.utf8)))
        let model=SharedFoldersModel(page:page)
        model.send("enterFolder",["id":"m"])
        XCTAssertEqual(page.operations,["enterFolder"])
        XCTAssertEqual(model.snapshot?.path,"")
        page.failure="engine gone"
        model.send("up")
        XCTAssertEqual(model.problem,"engine gone")
        page.failure=nil
        model.send("up")
        XCTAssertNil(model.problem)
    }
}
private final class FakeFolders: FoldersPage,@unchecked Sendable {
    let answer: FoldersSnapshot
    var failure: String?,operations: [String]=[]
    init(answer: FoldersSnapshot) { self.answer=answer }
    func request(_ operation: String,_ body: [String:any Sendable]) throws -> FoldersSnapshot {
        operations.append(operation)
        if let failure { throw HostConnectionError(failure) }
        return answer
    }
}
