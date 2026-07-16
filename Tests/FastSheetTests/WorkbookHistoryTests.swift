import XCTest
@testable import FastSheet

final class WorkbookHistoryTests: XCTestCase {
    func testUndoAndRedoRoundTripWorkbookChanges() {
        var history = WorkbookHistory()
        let original = Workbook()
        var edited = original
        edited.sheets[0].cells["A1"] = "42"

        history.record(original, selection: nil)
        XCTAssertEqual(history.undo(current: edited, selection: nil)?.workbook, original)
        XCTAssertEqual(history.redo(current: original, selection: nil)?.workbook, edited)
    }

    func testNewChangeClearsRedoHistory() {
        var history = WorkbookHistory()
        let original = Workbook()
        var firstEdit = original
        firstEdit.sheets[0].cells["A1"] = "1"
        var secondEdit = original
        secondEdit.sheets[0].cells["A1"] = "2"

        history.record(original, selection: nil)
        XCTAssertNotNil(history.undo(current: firstEdit, selection: nil))
        history.record(secondEdit, selection: nil)
        XCTAssertNil(history.redo(current: secondEdit, selection: nil))
    }

    func testHistorySupportsMultipleUndoLevels() {
        var history = WorkbookHistory()
        let first = Workbook()
        var second = first
        second.sheets[0].cells["A1"] = "1"
        var third = second
        third.sheets[0].cells["A1"] = "2"

        history.record(first, selection: nil)
        history.record(second, selection: nil)
        XCTAssertEqual(history.undo(current: third, selection: nil)?.workbook, second)
        XCTAssertEqual(history.undo(current: second, selection: nil)?.workbook, first)
    }

    func testUndoFocusesUpperLeftCellOfAffectedRange() {
        var history = WorkbookHistory()
        let original = Workbook()
        var edited = original
        edited.sheets[0].cells["C5"] = "1"
        let affectedRange = CellSelection(
            anchor: CellPosition(row: 8, column: 6),
            active: CellPosition(row: 4, column: 2)
        )

        history.record(original, selection: affectedRange)
        let restored = history.undo(current: edited, selection: nil)
        XCTAssertEqual(restored?.selection?.active, CellPosition(row: 4, column: 2))
        XCTAssertEqual(restored?.selection?.rows, 4...8)
        XCTAssertEqual(restored?.selection?.columns, 2...6)
    }
}
