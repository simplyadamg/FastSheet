import XCTest
@testable import FastSheet

final class ClipboardTests: XCTestCase {
    func testCopiedFormulaReferencesShiftRelativeParts() {
        let formula = "=A1+$B2+C$3+$D$4+SUM(E:E)"
        XCTAssertEqual(
            FormulaReferenceTranslator.translate(formula, rowDelta: 2, columnDelta: 1),
            "=B3+$B4+D$3+$D$4+SUM(F:F)"
        )
    }

    func testAbsoluteReferencesEvaluate() {
        let engine = FormulaEngine(cells: [
            "A1": "2",
            "B1": "3",
            "A2": "4",
            "B2": "=$A$1+B$1+$A2"
        ])
        XCTAssertEqual(engine.displayValue(for: "B2"), "9")
    }

    func testClipboardPayloadRoundTripsRawFormulasAndEmptyCells() throws {
        let payload = FastSheetClipboardPayload(
            sourceRow: 2,
            sourceColumn: 3,
            values: [["=A1+1", nil], ["7", "text"]],
            isCut: false
        )
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(FastSheetClipboardPayload.self, from: data), payload)
    }
}
