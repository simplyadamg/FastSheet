import XCTest
@testable import FastSheet

@MainActor
final class FrozenHeaderGeometryTests: XCTestCase {
    func testRowsRemainTopToBottomAfterVerticalScrolling() {
        let offset = SpreadsheetGridView.cellHeight * 12.5
        let row12 = FrozenHeaderGeometry.rowFrame(12, verticalOffset: offset)
        let row13 = FrozenHeaderGeometry.rowFrame(13, verticalOffset: offset)

        XCTAssertEqual(row12.minY, -SpreadsheetGridView.cellHeight / 2)
        XCTAssertEqual(row13.minY, SpreadsheetGridView.cellHeight / 2)
        XCTAssertLessThan(row12.minY, row13.minY)
    }

    func testRowHitTestingMatchesScrolledDrawing() {
        let offset = SpreadsheetGridView.cellHeight * 12.5

        XCTAssertEqual(
            FrozenHeaderGeometry.row(
                at: SpreadsheetGridView.cellHeight / 2,
                verticalOffset: offset
            ),
            13
        )
    }

    func testColumnHitTestingMatchesScrolledDrawing() {
        let offset = SpreadsheetGridView.rowHeaderWidth
            + SpreadsheetGridView.cellWidth * 4.25
        let column = FrozenHeaderGeometry.column(
            at: SpreadsheetGridView.rowHeaderWidth + SpreadsheetGridView.cellWidth / 2,
            horizontalOffset: offset
        )

        XCTAssertEqual(column, 5)
    }

    func testNavigationKeepsCellClearOfFrozenHeaders() {
        let visible = NSRect(x: 300, y: 280, width: 600, height: 400)
        let target = NSRect(x: 310, y: 290, width: 110, height: 28)
        let origin = FrozenHeaderGeometry.scrollOrigin(revealing: target, within: visible)

        XCTAssertEqual(origin.x + SpreadsheetGridView.rowHeaderWidth, target.minX)
        XCTAssertEqual(origin.y + SpreadsheetGridView.columnHeaderHeight, target.minY)
    }

    func testNavigationBackToFirstCellDoesNotOverscroll() {
        let visible = NSRect(x: 300, y: 280, width: 600, height: 400)
        let firstCell = NSRect(
            x: SpreadsheetGridView.rowHeaderWidth,
            y: SpreadsheetGridView.columnHeaderHeight,
            width: SpreadsheetGridView.cellWidth,
            height: SpreadsheetGridView.cellHeight
        )
        let origin = FrozenHeaderGeometry.scrollOrigin(revealing: firstCell, within: visible)

        XCTAssertEqual(origin, .zero)
    }
}
