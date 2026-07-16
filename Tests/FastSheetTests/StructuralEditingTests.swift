import XCTest
@testable import FastSheet

final class StructuralEditingTests: XCTestCase {
    func testInsertedRowMovesCellsSizesAndFormulaReferences() {
        let sheet = Sheet(
            name: "Sheet 1",
            cells: [
                "A1": "2",
                "A2": "3",
                "B1": "=A1+A2",
                "C1": "=SUM(A1:A2)"
            ],
            rowHeights: [1: 42]
        )

        let result = SheetStructuralEditor.applying(
            to: sheet,
            axis: .row,
            operation: .insert,
            index: 1,
            rowCount: 100,
            columnCount: 26
        )

        XCTAssertEqual(result.cells["A1"], "2")
        XCTAssertEqual(result.cells["A3"], "3")
        XCTAssertEqual(result.cells["B1"], "=A1+A3")
        XCTAssertEqual(result.cells["C1"], "=SUM(A1:A3)")
        XCTAssertEqual(result.rowHeights[2], 42)
        XCTAssertNil(result.rowHeights[1])
    }

    func testInsertedColumnMovesAbsoluteAndFullColumnReferences() {
        let sheet = Sheet(
            name: "Sheet 1",
            cells: [
                "B1": "4",
                "D1": "=$B$1+SUM(B:B)"
            ],
            columnWidths: [1: 180]
        )

        let result = SheetStructuralEditor.applying(
            to: sheet,
            axis: .column,
            operation: .insert,
            index: 1,
            rowCount: 100,
            columnCount: 26
        )

        XCTAssertEqual(result.cells["C1"], "4")
        XCTAssertEqual(result.cells["E1"], "=$C$1+SUM(C:C)")
        XCTAssertEqual(result.columnWidths[2], 180)
    }

    func testDeletingRowRemovesItsCellsAndShrinksRanges() {
        let sheet = Sheet(name: "Sheet 1", cells: [
            "A1": "1",
            "A2": "2",
            "A3": "3",
            "B1": "=SUM(A1:A3)",
            "C1": "=A2"
        ])

        let result = SheetStructuralEditor.applying(
            to: sheet,
            axis: .row,
            operation: .delete,
            index: 1,
            rowCount: 100,
            columnCount: 26
        )

        XCTAssertEqual(result.cells["A1"], "1")
        XCTAssertEqual(result.cells["A2"], "3")
        XCTAssertEqual(result.cells["B1"], "=SUM(A1:A2)")
        XCTAssertEqual(result.cells["C1"], "=#REF!")
    }

    func testLegacySheetDecodingDefaultsSizingData() throws {
        let json = #"{"name":"Legacy","cells":{"A1":"7"}}"#.data(using: .utf8)!
        let sheet = try JSONDecoder().decode(Sheet.self, from: json)

        XCTAssertEqual(sheet.name, "Legacy")
        XCTAssertEqual(sheet.cells["A1"], "7")
        XCTAssertTrue(sheet.rowHeights.isEmpty)
        XCTAssertTrue(sheet.columnWidths.isEmpty)
    }
}
