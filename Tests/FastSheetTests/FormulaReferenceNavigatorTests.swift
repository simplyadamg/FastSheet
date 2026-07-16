import XCTest
@testable import FastSheet

final class FormulaReferenceNavigatorTests: XCTestCase {
    func testArrowStartsFromFormulaCellAndInsertsDestinationReference() {
        let selection = FormulaReferenceNavigator.move(
            current: nil,
            startingAt: CellPosition(row: 4, column: 4),
            rowDelta: -1,
            columnDelta: 0,
            extending: false,
            rowCount: 100,
            columnCount: 26
        )

        XCTAssertEqual(selection.active, CellPosition(row: 3, column: 4))
        XCTAssertEqual(FormulaReferenceNavigator.referenceText(for: selection), "E4")
    }

    func testConsecutiveArrowsReplaceTheCurrentSingleReference() {
        let initial = CellSelection(
            anchor: CellPosition(row: 3, column: 4),
            active: CellPosition(row: 3, column: 4)
        )
        let selection = FormulaReferenceNavigator.move(
            current: initial,
            startingAt: CellPosition(row: 4, column: 4),
            rowDelta: 0,
            columnDelta: 1,
            extending: false,
            rowCount: 100,
            columnCount: 26
        )

        XCTAssertEqual(FormulaReferenceNavigator.referenceText(for: selection), "F4")
    }

    func testShiftArrowExtendsAReferenceRange() {
        let initial = CellSelection(
            anchor: CellPosition(row: 0, column: 0),
            active: CellPosition(row: 0, column: 0)
        )
        let selection = FormulaReferenceNavigator.move(
            current: initial,
            startingAt: CellPosition(row: 5, column: 5),
            rowDelta: 2,
            columnDelta: 1,
            extending: true,
            rowCount: 100,
            columnCount: 26
        )

        XCTAssertEqual(FormulaReferenceNavigator.referenceText(for: selection), "A1:B3")
    }

    func testReferenceNavigationStopsAtSheetEdges() {
        let selection = FormulaReferenceNavigator.move(
            current: nil,
            startingAt: CellPosition(row: 0, column: 0),
            rowDelta: -1,
            columnDelta: -1,
            extending: false,
            rowCount: 100,
            columnCount: 26
        )

        XCTAssertEqual(selection.active, CellPosition(row: 0, column: 0))
        XCTAssertEqual(FormulaReferenceNavigator.referenceText(for: selection), "A1")
    }
}
