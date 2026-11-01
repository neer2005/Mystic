import Foundation
import XCTest
import MysticCore
@testable import MysticDesktop

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private func answering(_ code: Int,_ body: String) -> UpdateChecker {
        UpdateChecker { request in
            XCTAssertEqual(request.url,UpdateCheck.latestRelease)
            XCTAssertEqual(request.value(forHTTPHeaderField:"User-Agent"),"Mystic/0.1.0 (macOS)")
            return (Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:nil,headerFields:nil)!)
        }
    }
    func testANewerReleaseIsOfferedOncePerLaunch() async {
        let checker=answering(200,#"{"tag_name":"v0.2.0","html_url":"https://github.com/neer2005/Mystic/releases/tag/v0.2.0"}"#)
        await checker.startOnce(enabled:true,version:"0.1.0")
        XCTAssertEqual(checker.found?.version,"0.2.0")
        XCTAssertEqual(checker.status,"Mystic 0.2.0 is available")
        checker.dismiss();XCTAssertNil(checker.found)
        await checker.startOnce(enabled:true,version:"0.1.0")
        XCTAssertNil(checker.found,"one check per launch")
    }
    func testOffNoReleaseAndRateLimitsOfferNothing() async {
        let off=UpdateChecker { _ in XCTFail("no request while off");throw URLError(.notConnectedToInternet) }
        await off.startOnce(enabled:false,version:"0.1.0")
        XCTAssertEqual(off.status,"Not checked yet")
        let none=answering(404,#"{"message":"Not Found"}"#)
        await none.startOnce(enabled:true,version:"0.1.0")
        XCTAssertNil(none.found);XCTAssertEqual(none.status,"No release has been published yet")
        let limited=answering(403,"{}")
        await limited.startOnce(enabled:true,version:"0.1.0")
        XCTAssertNil(limited.found);XCTAssertTrue(limited.status.contains("rate limit"))
        let local=answering(200,"{}")
        await local.startOnce(enabled:true,version:nil)
        XCTAssertEqual(local.status,"Not checked: this build has no version")
    }
}
