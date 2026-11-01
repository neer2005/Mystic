import XCTest
import MysticCore
@testable import MysticDesktop

@MainActor
final class MacKeyboardLayoutTests: XCTestCase {
    func testThisMacsLayoutIsReadAsAReportTheWireCarries() throws {
        let report=try XCTUnwrap(KeyboardLayoutWatch.current(),"every Mac has a current keyboard layout")
        print("Keyboard layout report: \(report.source) \(report.tag)")
        XCTAssertTrue(report.tag.utf8.count <= 64 && report.tag.utf8.allSatisfy { (0x21...0x7E).contains($0) })
    }
}
