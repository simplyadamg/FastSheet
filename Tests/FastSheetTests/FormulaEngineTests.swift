import XCTest
@testable import FastSheet

final class FormulaEngineTests: XCTestCase {
    func testArithmeticAndReferences() {
        let engine = FormulaEngine(cells: [
            "A1": "2",
            "A2": "3",
            "B1": "=A1+A2*2",
            "B2": "=(A1+A2)*2"
        ])
        XCTAssertEqual(engine.displayValue(for: "B1"), "8")
        XCTAssertEqual(engine.displayValue(for: "B2"), "10")
    }

    func testSumRangeAndLiveDependencies() {
        let engine = FormulaEngine(cells: [
            "A1": "2",
            "A2": "3",
            "A3": "5",
            "B1": "=SUM(A1:A3)",
            "C1": "=B1*2"
        ])
        XCTAssertEqual(engine.displayValue(for: "B1"), "10")
        XCTAssertEqual(engine.displayValue(for: "C1"), "20")
    }

    func testFullColumnSum() {
        let engine = FormulaEngine(cells: [
            "D1": "1",
            "D2": "2",
            "D3": "3",
            "D4": "3",
            "B7": "=SUM(D:D)"
        ])
        XCTAssertEqual(engine.displayValue(for: "B7"), "9")
    }

    func testInvalidAndCircularFormulasShowErrors() {
        let engine = FormulaEngine(cells: [
            "A1": "=B1",
            "B1": "=A1",
            "C1": "=NOT_A_FORMULA"
        ])
        XCTAssertEqual(engine.displayValue(for: "A1"), "#CIRC!")
        XCTAssertEqual(engine.displayValue(for: "C1"), "#NAME?")
    }

    func testFormulaErrorsAreSpecificAndPropagateToDependents() {
        let engine = FormulaEngine(cells: [
            "A1": "=1/0",
            "A2": "=A1+2",
            "B1": "=#REF!",
            "B2": "=1+",
            "C1": "words",
            "C2": "=C1+1"
        ])

        XCTAssertEqual(engine.displayValue(for: "A1"), "#DIV/0!")
        XCTAssertEqual(engine.displayValue(for: "A2"), "#DIV/0!")
        XCTAssertEqual(engine.displayValue(for: "B1"), "#REF!")
        XCTAssertEqual(engine.displayValue(for: "B2"), "#ERROR!")
        XCTAssertEqual(engine.displayValue(for: "C2"), "#VALUE!")
    }

    func testSumIgnoresPlainTextButPropagatesFormulaErrors() {
        let engine = FormulaEngine(cells: [
            "A1": "2",
            "A2": "words",
            "A3": "=1/0",
            "B1": "=SUM(A1:A2)",
            "B2": "=SUM(A1:A3)"
        ])

        XCTAssertEqual(engine.displayValue(for: "B1"), "2")
        XCTAssertEqual(engine.displayValue(for: "B2"), "#DIV/0!")
    }

    func testColumnNamesAndCoordinates() {
        XCTAssertEqual(FormulaEngine.columnName(0), "A")
        XCTAssertEqual(FormulaEngine.columnName(25), "Z")
        XCTAssertEqual(FormulaEngine.columnName(26), "AA")
        XCTAssertEqual(FormulaEngine.coordinates(for: "AA12")?.row, 11)
        XCTAssertEqual(FormulaEngine.coordinates(for: "AA12")?.column, 26)
    }
}
