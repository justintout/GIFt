import XCTest
@testable import GiftCore

final class ScreenGridTests: XCTestCase {
    func testLinesStartAtTheFirstMultipleInsideTheRange() {
        XCTAssertEqual(ScreenGrid.lines(from: 1512, to: 2000, spacing: 100), [1600, 1700, 1800, 1900])
    }

    func testLinesOnADisplayLeftOfThePrimaryAreNegativeMultiples() {
        XCTAssertEqual(ScreenGrid.lines(from: -250, to: 0, spacing: 100), [-200, -100])
    }

    func testFineGridLabelsOnlyEveryHundredPoints() {
        let labeled = ScreenGrid.lines(from: 0, to: 300, spacing: 50).filter { ScreenGrid.isLabeled($0, spacing: 50) }
        XCTAssertEqual(labeled, [0, 100, 200])
    }
}
