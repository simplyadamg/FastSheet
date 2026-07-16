import XCTest
@testable import FastSheet

final class CellSelectionTests: XCTestCase {
    func testSelectionNormalizesReverseDrag() {
        let selection = CellSelection(
            anchor: CellPosition(row: 7, column: 5),
            active: CellPosition(row: 2, column: 1)
        )
        XCTAssertEqual(selection.rows, 2...7)
        XCTAssertEqual(selection.columns, 1...5)
    }

    func testSelectionContainsOnlyItsRectangle() {
        let selection = CellSelection(
            anchor: CellPosition(row: 1, column: 1),
            active: CellPosition(row: 3, column: 4)
        )
        XCTAssertTrue(selection.contains(row: 2, column: 3))
        XCTAssertFalse(selection.contains(row: 0, column: 3))
        XCTAssertFalse(selection.contains(row: 2, column: 5))
    }

    func testExtendingPreservesAnchor() {
        let original = CellSelection(
            anchor: CellPosition(row: 2, column: 2),
            active: CellPosition(row: 2, column: 2)
        )
        let extended = original.extending(to: CellPosition(row: 8, column: 6))
        XCTAssertEqual(extended.anchor, original.anchor)
        XCTAssertEqual(extended.active, CellPosition(row: 8, column: 6))
    }
}
