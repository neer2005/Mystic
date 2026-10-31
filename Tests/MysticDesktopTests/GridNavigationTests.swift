import XCTest
@testable import MysticDesktop

final class GridNavigationTests: XCTestCase {
    func testColumnsMatchAdaptiveGridLayout() {
        XCTAssertEqual(GridNavigation.columns(width:140,minimum:140,spacing:16),1)
        XCTAssertEqual(GridNavigation.columns(width:296,minimum:140,spacing:16),2)
        XCTAssertEqual(GridNavigation.columns(width:295,minimum:140,spacing:16),1)
        XCTAssertEqual(GridNavigation.columns(width:0,minimum:140,spacing:16),1)
    }
    func testMovesWithinAndBetweenRows() {
        let ids=Array(1...7) // 3 columns: [1 2 3] [4 5 6] [7]
        XCTAssertEqual(GridNavigation.target(ids:ids,from:2,move:.right,columns:3),3)
        XCTAssertEqual(GridNavigation.target(ids:ids,from:3,move:.right,columns:3),4,"Right from a row's end continues on the next row")
        XCTAssertEqual(GridNavigation.target(ids:ids,from:4,move:.left,columns:3),3)
        XCTAssertEqual(GridNavigation.target(ids:ids,from:2,move:.down,columns:3),5)
        XCTAssertEqual(GridNavigation.target(ids:ids,from:5,move:.up,columns:3),2)
    }
    func testEdgesStayPutExceptDownIntoAShortLastRow() {
        let ids=Array(1...7)
        XCTAssertEqual(GridNavigation.target(ids:ids,from:1,move:.left,columns:3),1)
        XCTAssertEqual(GridNavigation.target(ids:ids,from:2,move:.up,columns:3),2)
        XCTAssertEqual(GridNavigation.target(ids:ids,from:7,move:.right,columns:3),7)
        XCTAssertEqual(GridNavigation.target(ids:ids,from:7,move:.down,columns:3),7)
        XCTAssertEqual(GridNavigation.target(ids:ids,from:6,move:.down,columns:3),7,"Down with nothing directly below goes to the last item")
    }
    func testNoSelectionSelectsFirstItem() {
        XCTAssertEqual(GridNavigation.target(ids:[4,5,6],from:nil,move:.down,columns:2),4)
        XCTAssertEqual(GridNavigation.target(ids:[4,5,6],from:9,move:.left,columns:2),4,"A selection that is no longer listed restarts at the first item")
        XCTAssertNil(GridNavigation.target(ids:[Int](),from:nil,move:.right,columns:2))
    }
}

