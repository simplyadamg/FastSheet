import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Workbook

struct Sheet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Raw user input. Formula cells retain the leading "=".
    var cells: [String: String] = [:]
}

struct Workbook: Codable, Equatable {
    var sheets: [Sheet] = [Sheet(name: "Sheet 1")]
    var activeSheetIndex = 0

    mutating func normalize() {
        if sheets.isEmpty {
            sheets = [Sheet(name: "Sheet 1")]
        }
        activeSheetIndex = min(max(0, activeSheetIndex), sheets.count - 1)
    }
}

final class WorkbookStore {
    private let key = "fastSheetWorkbookV2"
    private let legacyKey = "fastSheetWorkbook"

    private struct LegacyWorkbook: Codable {
        var sheets: [Sheet]
        var active: Int
    }

    func load() -> Workbook {
        if
            let data = UserDefaults.standard.data(forKey: key),
            var workbook = try? JSONDecoder().decode(Workbook.self, from: data)
        {
            workbook.normalize()
            return workbook
        }

        if
            let data = UserDefaults.standard.data(forKey: legacyKey),
            let legacy = try? JSONDecoder().decode(LegacyWorkbook.self, from: data)
        {
            var migrated = Workbook(sheets: legacy.sheets, activeSheetIndex: legacy.active)
            migrated.normalize()
            save(migrated)
            return migrated
        }

        return Workbook()
    }

    func save(_ workbook: Workbook) {
        guard let data = try? JSONEncoder().encode(workbook) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct WorkbookHistoryEntry: Equatable {
    let workbook: Workbook
    let selection: CellSelection?
}

struct WorkbookHistory {
    private(set) var undoStack: [WorkbookHistoryEntry] = []
    private(set) var redoStack: [WorkbookHistoryEntry] = []
    private let limit = 100

    mutating func record(_ workbook: Workbook, selection: CellSelection?) {
        let entry = WorkbookHistoryEntry(workbook: workbook, selection: selection?.focusedAtUpperLeft)
        if undoStack.last != entry { undoStack.append(entry) }
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    mutating func undo(current: Workbook, selection: CellSelection?) -> WorkbookHistoryEntry? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(WorkbookHistoryEntry(workbook: current, selection: previous.selection))
        return previous
    }

    mutating func redo(current: Workbook, selection: CellSelection?) -> WorkbookHistoryEntry? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(WorkbookHistoryEntry(workbook: current, selection: next.selection))
        return next
    }
}

// MARK: - Formula evaluation

struct FormulaEngine {
    let cells: [String: String]
    private static let maximumSpreadsheetRows = 100

    func displayValue(for reference: String) -> String {
        let raw = cells[reference.uppercased()] ?? ""
        guard raw.hasPrefix("=") else { return raw }
        guard let number = numericValue(for: reference, visiting: []) else { return "" }
        return Self.format(number)
    }

    private func numericValue(for reference: String, visiting: Set<String>) -> Double? {
        let key = reference.uppercased()
        guard !visiting.contains(key) else { return nil }
        guard let raw = cells[key], !raw.isEmpty else { return 0 }
        if !raw.hasPrefix("=") {
            return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var nextVisiting = visiting
        nextVisiting.insert(key)
        var parser = ExpressionParser(
            expression: String(raw.dropFirst()),
            resolveCell: { cell in numericValue(for: cell, visiting: nextVisiting) },
            resolveRange: { start, end in
                references(in: start, through: end).compactMap {
                    numericValue(for: $0, visiting: nextVisiting)
                }
            }
        )
        return parser.parse()
    }

    private func references(in start: String, through end: String) -> [String] {
        guard let a = Self.rangeCoordinates(for: start), let b = Self.rangeCoordinates(for: end) else { return [] }
        let rowStart: Int
        let rowEnd: Int
        if a.row == nil, b.row == nil {
            rowStart = 0
            rowEnd = Self.maximumSpreadsheetRows - 1
        } else if let firstRow = a.row, let lastRow = b.row {
            rowStart = min(firstRow, lastRow)
            rowEnd = max(firstRow, lastRow)
        } else {
            return []
        }
        let rows = rowStart...rowEnd
        let columns = min(a.column, b.column)...max(a.column, b.column)
        return rows.flatMap { row in
            columns.map { column in "\(Self.columnName(column))\(row + 1)" }
        }
    }

    static func coordinates(for reference: String) -> (row: Int, column: Int)? {
        guard let result = rangeCoordinates(for: reference), let row = result.row else { return nil }
        return (row, result.column)
    }

    private static func rangeCoordinates(for reference: String) -> (row: Int?, column: Int)? {
        let upper = reference.replacingOccurrences(of: "$", with: "").uppercased()
        let letters = upper.prefix { $0.isLetter }
        let digits = upper.dropFirst(letters.count)
        guard !letters.isEmpty else { return nil }
        var column = 0
        for scalar in letters.unicodeScalars {
            column = column * 26 + Int(scalar.value - 64)
        }
        if digits.isEmpty { return (nil, column - 1) }
        guard let rowNumber = Int(digits), rowNumber > 0 else { return nil }
        return (rowNumber - 1, column - 1)
    }

    static func columnName(_ column: Int) -> String {
        var value = column + 1
        var result = ""
        while value > 0 {
            value -= 1
            result = String(UnicodeScalar(65 + value % 26)!) + result
            value /= 26
        }
        return result
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.10g", value)
    }
}

struct FormulaReferenceTranslator {
    static func translate(_ formula: String, rowDelta: Int, columnDelta: Int) -> String {
        guard formula.hasPrefix("=") else { return formula }
        var result = replacingMatches(
            in: formula,
            pattern: #"(?i)(\$?)([A-Z]+):(\$?)([A-Z]+)"#
        ) { groups in
            let first = shiftedColumn(groups[2], absolute: !groups[1].isEmpty, delta: columnDelta)
            let second = shiftedColumn(groups[4], absolute: !groups[3].isEmpty, delta: columnDelta)
            return groups[1] + first + ":" + groups[3] + second
        }
        result = replacingMatches(
            in: result,
            pattern: #"(?i)(\$?)([A-Z]+)(\$?)([0-9]+)"#
        ) { groups in
            let column = shiftedColumn(groups[2], absolute: !groups[1].isEmpty, delta: columnDelta)
            let originalRow = Int(groups[4]) ?? 1
            let row = groups[3].isEmpty ? max(1, originalRow + rowDelta) : originalRow
            return groups[1] + column + groups[3] + String(row)
        }
        return result
    }

    private static func shiftedColumn(_ letters: String, absolute: Bool, delta: Int) -> String {
        guard !absolute else { return letters.uppercased() }
        var index = 0
        for scalar in letters.uppercased().unicodeScalars {
            index = index * 26 + Int(scalar.value - 64)
        }
        return FormulaEngine.columnName(max(0, index - 1 + delta))
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        replacement: ([String]) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let mutable = NSMutableString(string: value)
        let matches = expression.matches(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        )
        for match in matches.reversed() {
            let source = value as NSString
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            mutable.replaceCharacters(in: match.range, with: replacement(groups))
        }
        return mutable as String
    }
}

private struct ExpressionParser {
    let characters: [Character]
    var position = 0
    let resolveCell: (String) -> Double?
    let resolveRange: (String, String) -> [Double]

    init(
        expression: String,
        resolveCell: @escaping (String) -> Double?,
        resolveRange: @escaping (String, String) -> [Double]
    ) {
        characters = Array(expression)
        self.resolveCell = resolveCell
        self.resolveRange = resolveRange
    }

    mutating func parse() -> Double? {
        guard let value = parseExpression() else { return nil }
        skipSpaces()
        return position == characters.count ? value : nil
    }

    private mutating func parseExpression() -> Double? {
        guard var value = parseTerm() else { return nil }
        while true {
            skipSpaces()
            if consume("+") {
                guard let rhs = parseTerm() else { return nil }
                value += rhs
            } else if consume("-") {
                guard let rhs = parseTerm() else { return nil }
                value -= rhs
            } else {
                return value
            }
        }
    }

    private mutating func parseTerm() -> Double? {
        guard var value = parseFactor() else { return nil }
        while true {
            skipSpaces()
            if consume("*") {
                guard let rhs = parseFactor() else { return nil }
                value *= rhs
            } else if consume("/") {
                guard let rhs = parseFactor(), rhs != 0 else { return nil }
                value /= rhs
            } else {
                return value
            }
        }
    }

    private mutating func parseFactor() -> Double? {
        skipSpaces()
        if consume("-") { return parseFactor().map { -$0 } }
        if consume("(") {
            guard let value = parseExpression() else { return nil }
            skipSpaces()
            return consume(")") ? value : nil
        }
        if let number = readNumber() { return number }

        let referenceStart = position
        if let reference = readCellReference() {
            return resolveCell(reference.replacingOccurrences(of: "$", with: ""))
        }
        position = referenceStart

        guard let identifier = readIdentifier() else { return nil }
        if identifier.uppercased() == "SUM" {
            skipSpaces()
            guard consume("("), let start = readRangeReference() else { return nil }
            skipSpaces()
            let values: [Double]
            if consume(":") {
                guard let end = readRangeReference() else { return nil }
                values = resolveRange(start, end)
            } else {
                values = [resolveCell(start.replacingOccurrences(of: "$", with: "")) ?? 0]
            }
            skipSpaces()
            guard consume(")") else { return nil }
            return values.reduce(0, +)
        }

        return nil
    }

    private mutating func readNumber() -> Double? {
        skipSpaces()
        let start = position
        var sawDot = false
        while position < characters.count {
            let character = characters[position]
            if character.isNumber {
                position += 1
            } else if character == ".", !sawDot {
                sawDot = true
                position += 1
            } else {
                break
            }
        }
        guard position > start else { return nil }
        return Double(String(characters[start..<position]))
    }

    private mutating func readIdentifier() -> String? {
        skipSpaces()
        let start = position
        while position < characters.count, characters[position].isLetter { position += 1 }
        guard position > start else { return nil }
        return String(characters[start..<position])
    }

    private mutating func readCellReference() -> String? {
        let start = position
        skipSpaces()
        let columnAbsolute = consume("$")
        let lettersStart = position
        while position < characters.count, characters[position].isLetter { position += 1 }
        guard position > lettersStart else { position = start; return nil }
        let letters = String(characters[lettersStart..<position])
        let rowAbsolute = consume("$")
        let digits = readDigits()
        guard !digits.isEmpty else { position = start; return nil }
        return ((columnAbsolute ? "$" : "") + letters + (rowAbsolute ? "$" : "") + digits).uppercased()
    }

    private mutating func readRangeReference() -> String? {
        let start = position
        skipSpaces()
        let columnAbsolute = consume("$")
        let lettersStart = position
        while position < characters.count, characters[position].isLetter { position += 1 }
        guard position > lettersStart else { position = start; return nil }
        let letters = String(characters[lettersStart..<position])
        let rowAbsolute = consume("$")
        let digits = readDigits()
        return ((columnAbsolute ? "$" : "") + letters + (rowAbsolute ? "$" : "") + digits).uppercased()
    }

    private mutating func readDigits() -> String {
        let start = position
        while position < characters.count, characters[position].isNumber { position += 1 }
        return String(characters[start..<position])
    }

    private mutating func skipSpaces() {
        while position < characters.count, characters[position].isWhitespace { position += 1 }
    }

    private mutating func consume(_ character: Character) -> Bool {
        guard position < characters.count, characters[position] == character else { return false }
        position += 1
        return true
    }
}

// MARK: - Grid

struct CellPosition: Hashable {
    let row: Int
    let column: Int
}

struct CellSelection: Equatable {
    let anchor: CellPosition
    let active: CellPosition

    var rows: ClosedRange<Int> { min(anchor.row, active.row)...max(anchor.row, active.row) }
    var columns: ClosedRange<Int> { min(anchor.column, active.column)...max(anchor.column, active.column) }

    func contains(row: Int, column: Int) -> Bool {
        rows.contains(row) && columns.contains(column)
    }

    func extending(to position: CellPosition) -> CellSelection {
        CellSelection(anchor: anchor, active: position)
    }

    var focusedAtUpperLeft: CellSelection {
        CellSelection(
            anchor: CellPosition(row: rows.upperBound, column: columns.upperBound),
            active: CellPosition(row: rows.lowerBound, column: columns.lowerBound)
        )
    }
}

struct FormulaReferenceNavigator {
    static func move(
        current: CellSelection?,
        startingAt start: CellPosition,
        rowDelta: Int,
        columnDelta: Int,
        extending: Bool,
        rowCount: Int,
        columnCount: Int
    ) -> CellSelection {
        let currentPosition = current?.active ?? start
        let destination = CellPosition(
            row: min(max(0, currentPosition.row + rowDelta), rowCount - 1),
            column: min(max(0, currentPosition.column + columnDelta), columnCount - 1)
        )

        if extending {
            let anchor = current?.anchor ?? start
            return CellSelection(anchor: anchor, active: destination)
        }
        return CellSelection(anchor: destination, active: destination)
    }

    static func referenceText(for selection: CellSelection) -> String {
        let first = reference(row: selection.rows.lowerBound, column: selection.columns.lowerBound)
        guard selection.rows.count > 1 || selection.columns.count > 1 else { return first }
        let last = reference(row: selection.rows.upperBound, column: selection.columns.upperBound)
        return "\(first):\(last)"
    }

    private static func reference(row: Int, column: Int) -> String {
        "\(FormulaEngine.columnName(column))\(row + 1)"
    }
}

struct FastSheetClipboardPayload: Codable, Equatable {
    let sourceRow: Int
    let sourceColumn: Int
    let values: [[String?]]
    let isCut: Bool
}

private extension NSPasteboard.PasteboardType {
    static let fastSheetCells = NSPasteboard.PasteboardType("com.fastsheet.cells")
}

final class GridHeaderField: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }

    func setSelected(_ selected: Bool) {
        backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.windowBackgroundColor
        textColor = selected ? .labelColor : .secondaryLabelColor
    }
}

final class FillHandleView: NSView {
    var onDragFinished: ((NSPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 2
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        while let tracked = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if tracked.type == .leftMouseUp {
                onDragFinished?(tracked.locationInWindow)
                break
            }
        }
    }
}

final class GridCellField: NSTextField {
    let row: Int
    let column: Int
    var onSelect: ((GridCellField, Bool) -> Bool)?
    var onBeginEditing: ((GridCellField, String?) -> Void)?
    var onNavigate: ((GridCellField, Int, Int, Bool, Bool) -> Void)?
    var onClear: ((GridCellField) -> Void)?
    var onDragSelection: ((NSPoint) -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = true
        backgroundColor = .clear
        textColor = .labelColor
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        if currentEditor() != nil {
            super.mouseDown(with: event)
            return
        }
        let handledAsFormulaReference = onSelect?(
            self,
            event.modifierFlags.contains(.shift)
        ) == true
        if handledAsFormulaReference { return }
        if event.clickCount >= 2 { onBeginEditing?(self, nil) }
        guard event.clickCount == 1, let window else { return }
        while let tracked = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if tracked.type == .leftMouseDragged { onDragSelection?(tracked.locationInWindow) }
            if tracked.type == .leftMouseUp { break }
        }
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.keyCode {
            case 8: onCopy?(); return // C
            case 7: onCut?(); return // X
            case 9: onPaste?(); return // V
            case 6 where event.modifierFlags.contains(.shift): onRedo?(); return // Shift-Z
            case 6: onUndo?(); return // Z
            default: break
            }
        }
        switch event.keyCode {
        case 123: onNavigate?(self, 0, -1, command, event.modifierFlags.contains(.shift))
        case 124: onNavigate?(self, 0, 1, command, event.modifierFlags.contains(.shift))
        case 125: onNavigate?(self, 1, 0, command, event.modifierFlags.contains(.shift))
        case 126: onNavigate?(self, -1, 0, command, event.modifierFlags.contains(.shift))
        case 36, 76:
            onNavigate?(self, event.modifierFlags.contains(.shift) ? -1 : 1, 0, false, false)
        case 48:
            onNavigate?(self, 0, event.modifierFlags.contains(.shift) ? -1 : 1, false, false)
        case 51, 117:
            onClear?(self)
        case 120: // F2
            onBeginEditing?(self, nil)
        default:
            let blockedModifiers: NSEvent.ModifierFlags = [.command, .control]
            if event.modifierFlags.intersection(blockedModifiers).isEmpty,
               let characters = event.characters,
               !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                onBeginEditing?(self, characters)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    func setSelectionState(selected: Bool, active: Bool) {
        if active {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12)
        } else if selected {
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
            backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
        } else {
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.separatorColor.cgColor
            backgroundColor = .clear
        }
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
struct FrozenHeaderGeometry {
    static func columnFrame(_ column: Int, horizontalOffset: CGFloat) -> NSRect {
        NSRect(
            x: SpreadsheetGridView.rowHeaderWidth
                + CGFloat(column) * SpreadsheetGridView.cellWidth
                - horizontalOffset,
            y: 0,
            width: SpreadsheetGridView.cellWidth,
            height: SpreadsheetGridView.columnHeaderHeight
        )
    }

    static func rowFrame(_ row: Int, verticalOffset: CGFloat) -> NSRect {
        NSRect(
            x: 0,
            y: CGFloat(row) * SpreadsheetGridView.cellHeight - verticalOffset,
            width: SpreadsheetGridView.rowHeaderWidth,
            height: SpreadsheetGridView.cellHeight
        )
    }

    static func column(at viewX: CGFloat, horizontalOffset: CGFloat) -> Int? {
        let documentX = viewX + horizontalOffset
        let column = Int(floor(
            (documentX - SpreadsheetGridView.rowHeaderWidth) / SpreadsheetGridView.cellWidth
        ))
        return (0..<SpreadsheetGridView.columnCount).contains(column) ? column : nil
    }

    static func row(at viewY: CGFloat, verticalOffset: CGFloat) -> Int? {
        let row = Int(floor((viewY + verticalOffset) / SpreadsheetGridView.cellHeight))
        return (0..<SpreadsheetGridView.rowCount).contains(row) ? row : nil
    }

    static func scrollOrigin(revealing frame: NSRect, within visible: NSRect) -> NSPoint {
        var origin = visible.origin

        let leftEdge = origin.x + SpreadsheetGridView.rowHeaderWidth
        if frame.minX < leftEdge {
            origin.x = frame.minX - SpreadsheetGridView.rowHeaderWidth
        } else if frame.maxX > visible.maxX {
            origin.x = frame.maxX - visible.width
        }

        let topEdge = origin.y + SpreadsheetGridView.columnHeaderHeight
        if frame.minY < topEdge {
            origin.y = frame.minY - SpreadsheetGridView.columnHeaderHeight
        } else if frame.maxY > visible.maxY {
            origin.y = frame.maxY - visible.height
        }

        origin.x = max(0, origin.x)
        origin.y = max(0, origin.y)
        return origin
    }
}

final class HeaderTrackingScrollView: NSScrollView {
    var onScroll: (() -> Void)?

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        onScroll?()
    }
}

final class FrozenHeaderView: FlippedView {
    enum Axis {
        case columns
        case rows
    }

    let axis: Axis
    weak var scrollView: NSScrollView?
    var selection: CellSelection?
    var onSelectRow: ((Int) -> Void)?
    var onSelectColumn: ((Int) -> Void)?
    var onSelectAll: (() -> Void)?

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()

        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let offset = scrollView?.contentView.bounds.origin ?? .zero
        switch axis {
        case .columns:
            drawColumnHeaders(horizontalOffset: offset.x)
        case .rows:
            drawRowHeaders(verticalOffset: offset.y)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let offset = scrollView?.contentView.bounds.origin ?? .zero
        switch axis {
        case .columns:
            if point.x < SpreadsheetGridView.rowHeaderWidth {
                onSelectAll?()
            } else if let column = FrozenHeaderGeometry.column(
                at: point.x,
                horizontalOffset: offset.x
            ) {
                onSelectColumn?(column)
            }
        case .rows:
            if let row = FrozenHeaderGeometry.row(at: point.y, verticalOffset: offset.y) {
                onSelectRow?(row)
            }
        }
    }

    func update(selection: CellSelection?) {
        self.selection = selection
        needsDisplay = true
    }

    private func drawColumnHeaders(horizontalOffset: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(
            x: SpreadsheetGridView.rowHeaderWidth,
            y: 0,
            width: max(0, bounds.width - SpreadsheetGridView.rowHeaderWidth),
            height: bounds.height
        )).addClip()

        for column in 0..<SpreadsheetGridView.columnCount {
            let frame = FrozenHeaderGeometry.columnFrame(column, horizontalOffset: horizontalOffset)
            guard frame.intersects(bounds) else { continue }
            drawHeader(
                FormulaEngine.columnName(column),
                in: frame,
                alignment: .center,
                selected: selection?.columns.contains(column) == true
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let selectsAll = selection?.rows == 0...(SpreadsheetGridView.rowCount - 1)
            && selection?.columns == 0...(SpreadsheetGridView.columnCount - 1)
        drawHeader(
            "",
            in: NSRect(
                x: 0,
                y: 0,
                width: SpreadsheetGridView.rowHeaderWidth,
                height: SpreadsheetGridView.columnHeaderHeight
            ),
            alignment: .center,
            selected: selectsAll
        )
    }

    private func drawRowHeaders(verticalOffset: CGFloat) {
        for row in 0..<SpreadsheetGridView.rowCount {
            let frame = FrozenHeaderGeometry.rowFrame(row, verticalOffset: verticalOffset)
            guard frame.intersects(bounds) else { continue }
            drawHeader(
                String(row + 1),
                in: frame,
                alignment: .right,
                selected: selection?.rows.contains(row) == true
            )
        }
    }

    private func drawHeader(
        _ text: String,
        in frame: NSRect,
        alignment: NSTextAlignment,
        selected: Bool
    ) {
        let background = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.windowBackgroundColor
        background.setFill()
        frame.fill()

        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: frame.integral)
        border.lineWidth = 1
        border.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(
            in: frame.insetBy(dx: alignment == .right ? 6 : 3, dy: 6),
            withAttributes: attributes
        )
    }
}

final class SpreadsheetGridView: FlippedView {
    static let rowCount = 100
    static let columnCount = 26
    static let rowHeaderWidth: CGFloat = 44
    static let columnHeaderHeight: CGFloat = 26
    static let cellWidth: CGFloat = 110
    static let cellHeight: CGFloat = 28

    private(set) var fields: [[GridCellField]] = []
    private(set) var rowHeaders: [GridHeaderField] = []
    private(set) var columnHeaders: [GridHeaderField] = []
    private var cornerHeader: GridHeaderField?
    private let fillHandle = FillHandleView(frame: .zero)
    var onSelectRow: ((Int) -> Void)?
    var onSelectColumn: ((Int) -> Void)?
    var onSelectAll: (() -> Void)?
    var onFillHandleDrag: ((NSPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildGrid()
    }

    required init?(coder: NSCoder) { nil }

    private func buildGrid() {
        frame.size = NSSize(
            width: Self.rowHeaderWidth + CGFloat(Self.columnCount) * Self.cellWidth,
            height: Self.columnHeaderHeight + CGFloat(Self.rowCount) * Self.cellHeight
        )

        let corner = headerLabel("", alignment: .center)
        corner.onClick = { [weak self] in self?.onSelectAll?() }
        corner.frame = NSRect(x: 0, y: 0, width: Self.rowHeaderWidth, height: Self.columnHeaderHeight)
        addSubview(corner)
        cornerHeader = corner

        for column in 0..<Self.columnCount {
            let label = headerLabel(FormulaEngine.columnName(column), alignment: .center)
            label.onClick = { [weak self] in self?.onSelectColumn?(column) }
            label.frame = NSRect(
                x: Self.rowHeaderWidth + CGFloat(column) * Self.cellWidth,
                y: 0,
                width: Self.cellWidth,
                height: Self.columnHeaderHeight
            )
            addSubview(label)
            columnHeaders.append(label)
        }

        for row in 0..<Self.rowCount {
            let rowLabel = headerLabel(String(row + 1), alignment: .right)
            rowLabel.onClick = { [weak self] in self?.onSelectRow?(row) }
            rowLabel.frame = NSRect(
                x: 0,
                y: Self.columnHeaderHeight + CGFloat(row) * Self.cellHeight,
                width: Self.rowHeaderWidth,
                height: Self.cellHeight
            )
            addSubview(rowLabel)
            rowHeaders.append(rowLabel)

            var rowFields: [GridCellField] = []
            for column in 0..<Self.columnCount {
                let field = GridCellField(row: row, column: column)
                field.frame = NSRect(
                    x: Self.rowHeaderWidth + CGFloat(column) * Self.cellWidth,
                    y: Self.columnHeaderHeight + CGFloat(row) * Self.cellHeight,
                    width: Self.cellWidth,
                    height: Self.cellHeight
                )
                addSubview(field)
                rowFields.append(field)
            }
            fields.append(rowFields)
        }

        fillHandle.onDragFinished = { [weak self] point in self?.onFillHandleDrag?(point) }
        addSubview(fillHandle)
    }

    private func headerLabel(_ text: String, alignment: NSTextAlignment) -> GridHeaderField {
        let label = GridHeaderField(labelWithString: text)
        label.alignment = alignment
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.drawsBackground = true
        label.backgroundColor = NSColor.windowBackgroundColor
        label.wantsLayer = true
        label.layer?.borderWidth = 0.5
        label.layer?.borderColor = NSColor.separatorColor.cgColor
        return label
    }

    func field(row: Int, column: Int) -> GridCellField? {
        guard fields.indices.contains(row), fields[row].indices.contains(column) else { return nil }
        return fields[row][column]
    }

    func updateHeaderSelection(_ selection: CellSelection?) {
        for (row, header) in rowHeaders.enumerated() {
            header.setSelected(selection?.rows.contains(row) == true)
        }
        for (column, header) in columnHeaders.enumerated() {
            header.setSelected(selection?.columns.contains(column) == true)
        }
        let selectsAll = selection?.rows == 0...(Self.rowCount - 1)
            && selection?.columns == 0...(Self.columnCount - 1)
        cornerHeader?.setSelected(selectsAll)
    }

    func updateFillHandle(_ selection: CellSelection?) {
        guard let selection,
              let field = field(row: selection.rows.upperBound, column: selection.columns.upperBound)
        else {
            fillHandle.isHidden = true
            return
        }
        fillHandle.frame = NSRect(
            x: field.frame.maxX - 5,
            y: field.frame.maxY - 5,
            width: 8,
            height: 8
        )
        fillHandle.isHidden = false
    }
}

// MARK: - Popup

final class FastSheetPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class SheetController: NSViewController, NSTextFieldDelegate {
    private var workbook: Workbook
    private let saveWorkbook: (Workbook) -> Void
    private let scrollView = HeaderTrackingScrollView()
    private let gridView = SpreadsheetGridView(frame: .zero)
    private let frozenColumnHeaders = FrozenHeaderView(axis: .columns)
    private let frozenRowHeaders = FrozenHeaderView(axis: .rows)
    private let cellReferenceField = NSTextField(frame: .zero)
    private let formulaBar = NSTextField(frame: .zero)
    private let tabs = NSStackView()
    private weak var selectedField: GridCellField?
    private var selection: CellSelection?
    private weak var formulaEditingField: GridCellField?
    private var formulaReferenceSelection: CellSelection?
    private var formulaReferenceTextRange: NSRange?
    private var formulaReferenceEditorText: String?
    private var isApplyingFormulaReference = false
    private var history = WorkbookHistory()

    init(workbook: Workbook, save: @escaping (Workbook) -> Void) {
        var normalized = workbook
        normalized.normalize()
        self.workbook = normalized
        saveWorkbook = save
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        view = effect
        buildInterface()
        loadActiveSheet()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if selectedField == nil, let firstCell = gridView.field(row: 0, column: 0) { selectCell(firstCell) }
    }

    private func buildInterface() {
        let addSheetButton = NSButton(title: "+", target: self, action: #selector(addSheet))
        addSheetButton.toolTip = "New sheet"
        addSheetButton.bezelStyle = .texturedRounded

        cellReferenceField.isEditable = false
        cellReferenceField.isSelectable = false
        cellReferenceField.isBezeled = true
        cellReferenceField.alignment = .center
        cellReferenceField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        cellReferenceField.placeholderString = "Cell"

        formulaBar.delegate = self
        formulaBar.isEditable = true
        formulaBar.isSelectable = true
        formulaBar.isBezeled = true
        formulaBar.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        formulaBar.placeholderString = "Enter a value or formula"

        let formulaRow = NSStackView(views: [cellReferenceField, formulaBar, addSheetButton])
        formulaRow.orientation = .horizontal
        formulaRow.alignment = .centerY
        formulaRow.spacing = 6
        formulaRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(formulaRow)

        scrollView.documentView = gridView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        frozenColumnHeaders.scrollView = scrollView
        frozenRowHeaders.scrollView = scrollView
        frozenColumnHeaders.translatesAutoresizingMaskIntoConstraints = false
        frozenRowHeaders.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frozenColumnHeaders)
        view.addSubview(frozenRowHeaders)
        scrollView.onScroll = { [weak self] in self?.refreshFrozenHeaders() }

        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 4
        tabs.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabs)

        NSLayoutConstraint.activate([
            formulaRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            formulaRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            formulaRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            formulaRow.heightAnchor.constraint(equalToConstant: 24),
            cellReferenceField.widthAnchor.constraint(equalToConstant: 72),

            scrollView.topAnchor.constraint(equalTo: formulaRow.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: tabs.topAnchor, constant: -7),

            frozenColumnHeaders.topAnchor.constraint(equalTo: scrollView.topAnchor),
            frozenColumnHeaders.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            frozenColumnHeaders.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            frozenColumnHeaders.heightAnchor.constraint(
                equalToConstant: SpreadsheetGridView.columnHeaderHeight
            ),

            frozenRowHeaders.topAnchor.constraint(equalTo: frozenColumnHeaders.bottomAnchor),
            frozenRowHeaders.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            frozenRowHeaders.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            frozenRowHeaders.widthAnchor.constraint(equalToConstant: SpreadsheetGridView.rowHeaderWidth),

            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            tabs.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            tabs.heightAnchor.constraint(equalToConstant: 24)
        ])

        for row in gridView.fields {
            for field in row {
                field.delegate = self
                field.onSelect = { [weak self] field, extending in
                    guard let self else { return false }
                    if self.insertFormulaReferenceIfNeeded(to: field, extending: extending) {
                        return true
                    }
                    self.selectCell(field, extending: extending)
                    return false
                }
                field.onBeginEditing = { [weak self] field, replacement in
                    self?.beginEditing(field, replacingWith: replacement)
                }
                field.onNavigate = { [weak self] field, rowDelta, columnDelta, jump, extending in
                    self?.moveSelection(
                        from: field,
                        rowDelta: rowDelta,
                        columnDelta: columnDelta,
                        jump: jump,
                        extending: extending
                    )
                }
                field.onClear = { [weak self] _ in self?.clearSelectedCells() }
                field.onDragSelection = { [weak self] point in self?.extendSelection(toWindowPoint: point) }
                field.onCopy = { [weak self] in self?.copySelection(isCut: false) }
                field.onCut = { [weak self] in self?.copySelection(isCut: true) }
                field.onPaste = { [weak self] in self?.pasteSelection() }
                field.onUndo = { [weak self] in self?.undoWorkbookChange() }
                field.onRedo = { [weak self] in self?.redoWorkbookChange() }
            }
        }
        gridView.onSelectRow = { [weak self] row in self?.selectRow(row) }
        gridView.onSelectColumn = { [weak self] column in self?.selectColumn(column) }
        gridView.onSelectAll = { [weak self] in self?.selectAllCells() }
        gridView.onFillHandleDrag = { [weak self] point in self?.fillSelection(toWindowPoint: point) }
        frozenColumnHeaders.onSelectColumn = { [weak self] column in self?.selectColumn(column) }
        frozenColumnHeaders.onSelectAll = { [weak self] in self?.selectAllCells() }
        frozenRowHeaders.onSelectRow = { [weak self] row in self?.selectRow(row) }
    }

    private var activeSheet: Sheet { workbook.sheets[workbook.activeSheetIndex] }

    private func reference(row: Int, column: Int) -> String {
        "\(FormulaEngine.columnName(column))\(row + 1)"
    }

    private func loadActiveSheet(focusing target: (row: Int, column: Int)? = nil) {
        let sheet = activeSheet
        let engine = FormulaEngine(cells: sheet.cells)
        for row in gridView.fields {
            for field in row {
                let key = reference(row: field.row, column: field.column)
                field.stringValue = engine.displayValue(for: key)
            }
        }
        applySelectionAppearance()
        rebuildTabs()

        if let target, let field = gridView.field(row: target.row, column: target.column) {
            scrollFieldToVisible(field)
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                self.selectCell(field, extending: false)
            }
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? GridCellField else { return }
        if selectedField !== field { selectCell(field, extending: false) }
        if formulaEditingField !== field {
            resetFormulaReferenceEntry()
            formulaEditingField = field
        }
        applySelectionAppearance()
    }

    func controlTextDidChange(_ notification: Notification) {
        if let editedField = notification.object as? NSTextField, editedField === formulaBar {
            return
        }
        guard let field = notification.object as? GridCellField,
              field === formulaEditingField,
              !isApplyingFormulaReference,
              let editor = field.currentEditor() as? NSTextView,
              editor.string != formulaReferenceEditorText
        else { return }

        formulaReferenceTextRange = nil
        formulaReferenceEditorText = nil
        formulaBar.stringValue = editor.string
        if !editor.string.hasPrefix("=") {
            formulaReferenceSelection = nil
        }
        applySelectionAppearance()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let editedField = notification.object as? NSTextField, editedField === formulaBar {
            commitFormulaBar()
            return
        }
        guard let field = notification.object as? GridCellField else { return }
        resetFormulaReferenceEntry()
        save(field)
        field.isEditable = false
        field.isSelectable = false
        loadActiveSheet()
        applySelectionAppearance()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard let field = control as? GridCellField else { return false }

        if field === formulaEditingField, textView.string.hasPrefix("=") {
            switch commandSelector {
            case #selector(NSResponder.moveLeft(_:)):
                moveFormulaReference(from: field, in: textView, rowDelta: 0, columnDelta: -1)
                return true
            case #selector(NSResponder.moveRight(_:)):
                moveFormulaReference(from: field, in: textView, rowDelta: 0, columnDelta: 1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                moveFormulaReference(from: field, in: textView, rowDelta: 1, columnDelta: 0)
                return true
            case #selector(NSResponder.moveUp(_:)):
                moveFormulaReference(from: field, in: textView, rowDelta: -1, columnDelta: 0)
                return true
            case #selector(NSResponder.moveLeftAndModifySelection(_:)):
                moveFormulaReference(
                    from: field,
                    in: textView,
                    rowDelta: 0,
                    columnDelta: -1,
                    extending: true
                )
                return true
            case #selector(NSResponder.moveRightAndModifySelection(_:)):
                moveFormulaReference(
                    from: field,
                    in: textView,
                    rowDelta: 0,
                    columnDelta: 1,
                    extending: true
                )
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                moveFormulaReference(
                    from: field,
                    in: textView,
                    rowDelta: 1,
                    columnDelta: 0,
                    extending: true
                )
                return true
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                moveFormulaReference(
                    from: field,
                    in: textView,
                    rowDelta: -1,
                    columnDelta: 0,
                    extending: true
                )
                return true
            default:
                break
            }
        }

        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(from: field, rowDelta: 0, columnDelta: 1, jump: false, extending: false)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            moveSelection(from: field, rowDelta: 0, columnDelta: -1, jump: false, extending: false)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let rowDelta = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1
            moveSelection(from: field, rowDelta: rowDelta, columnDelta: 0, jump: false, extending: false)
            return true
        default:
            return false
        }
    }

    private func selectCell(_ field: GridCellField, extending: Bool = false) {
        let position = CellPosition(row: field.row, column: field.column)
        if extending, let selection {
            self.selection = selection.extending(to: position)
        } else {
            selection = CellSelection(anchor: position, active: position)
        }
        selectedField = field
        field.isEditable = false
        field.isSelectable = false
        view.window?.makeFirstResponder(field)
        scrollFieldToVisible(field)
        applySelectionAppearance()
    }

    private func beginEditing(_ field: GridCellField, replacingWith replacement: String?) {
        resetFormulaReferenceEntry()
        selectCell(field, extending: false)
        let key = reference(row: field.row, column: field.column)
        let initialText = replacement ?? activeSheet.cells[key] ?? ""
        field.stringValue = initialText
        field.isEditable = true
        field.isSelectable = true
        field.selectText(nil)
        formulaBar.stringValue = initialText
        formulaEditingField = field
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, let editor = field.currentEditor() as? NSTextView else { return }
            editor.allowsUndo = true
            editor.string = initialText
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            self.formulaReferenceEditorText = nil
        }
    }

    private func moveFormulaReference(
        from field: GridCellField,
        in editor: NSTextView,
        rowDelta: Int,
        columnDelta: Int,
        extending: Bool = false
    ) {
        let nextSelection = FormulaReferenceNavigator.move(
            current: formulaReferenceSelection,
            startingAt: CellPosition(row: field.row, column: field.column),
            rowDelta: rowDelta,
            columnDelta: columnDelta,
            extending: extending,
            rowCount: SpreadsheetGridView.rowCount,
            columnCount: SpreadsheetGridView.columnCount
        )
        insertFormulaReference(nextSelection, into: editor, editingField: field)
    }

    private func insertFormulaReferenceIfNeeded(
        to field: GridCellField,
        extending: Bool
    ) -> Bool {
        guard let editingField = formulaEditingField,
              editingField !== field,
              let editor = editingField.currentEditor() as? NSTextView,
              editor.string.hasPrefix("=")
        else { return false }

        let position = CellPosition(row: field.row, column: field.column)
        let nextSelection: CellSelection
        if extending, let formulaReferenceSelection {
            nextSelection = formulaReferenceSelection.extending(to: position)
        } else {
            nextSelection = CellSelection(anchor: position, active: position)
        }
        insertFormulaReference(nextSelection, into: editor, editingField: editingField)
        return true
    }

    private func insertFormulaReference(
        _ referenceSelection: CellSelection,
        into editor: NSTextView,
        editingField: GridCellField
    ) {
        let currentLength = editor.string.utf16.count
        let selectedRange = editor.selectedRange()
        let savedRange = formulaReferenceTextRange
        let replacementRange: NSRange
        if let savedRange,
           savedRange.location <= currentLength,
           savedRange.location + savedRange.length <= currentLength {
            replacementRange = savedRange
        } else if selectedRange.location <= currentLength,
                  selectedRange.location + selectedRange.length <= currentLength {
            replacementRange = selectedRange
        } else {
            replacementRange = NSRange(location: currentLength, length: 0)
        }

        let referenceText = FormulaReferenceNavigator.referenceText(for: referenceSelection)
        isApplyingFormulaReference = true
        editor.insertText(referenceText, replacementRange: replacementRange)
        let insertedRange = NSRange(location: replacementRange.location, length: referenceText.utf16.count)
        editor.setSelectedRange(NSRange(location: NSMaxRange(insertedRange), length: 0))
        editingField.stringValue = editor.string
        isApplyingFormulaReference = false

        formulaReferenceSelection = referenceSelection
        formulaReferenceTextRange = insertedRange
        formulaReferenceEditorText = editor.string
        if let active = gridView.field(
            row: referenceSelection.active.row,
            column: referenceSelection.active.column
        ) {
            scrollFieldToVisible(active)
        }
        applySelectionAppearance()
    }

    private func resetFormulaReferenceEntry() {
        formulaEditingField = nil
        formulaReferenceSelection = nil
        formulaReferenceTextRange = nil
        formulaReferenceEditorText = nil
        isApplyingFormulaReference = false
    }

    private func commitFormulaBar() {
        guard let active = selection?.active else { return }
        let key = reference(row: active.row, column: active.column)
        let raw = formulaBar.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = workbook
        if raw.isEmpty {
            workbook.sheets[workbook.activeSheetIndex].cells.removeValue(forKey: key)
        } else {
            workbook.sheets[workbook.activeSheetIndex].cells[key] = raw
        }
        if workbook != previous {
            history.record(previous, selection: selection)
            persist()
        }
        loadActiveSheet()
        if let field = gridView.field(row: active.row, column: active.column) {
            selectedField = field
            view.window?.makeFirstResponder(field)
            applySelectionAppearance()
        }
    }

    private func clearSelectedCells() {
        guard let selection else { return }
        let previous = workbook
        for row in selection.rows {
            for column in selection.columns {
                workbook.sheets[workbook.activeSheetIndex].cells.removeValue(
                    forKey: reference(row: row, column: column)
                )
            }
        }
        guard workbook != previous else { return }
        history.record(previous, selection: selection)
        persist()
        loadActiveSheet()
        applySelectionAppearance()
    }

    private func copySelection(isCut: Bool) {
        guard let selection else { return }
        let engine = FormulaEngine(cells: activeSheet.cells)
        let rawValues: [[String?]] = selection.rows.map { row in
            selection.columns.map { column in
                activeSheet.cells[reference(row: row, column: column)]
            }
        }
        let plainText = selection.rows.map { row in
            selection.columns.map { column in
                engine.displayValue(for: reference(row: row, column: column))
                    .replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            }.joined(separator: "\t")
        }.joined(separator: "\n")

        let payload = FastSheetClipboardPayload(
            sourceRow: selection.rows.lowerBound,
            sourceColumn: selection.columns.lowerBound,
            values: rawValues,
            isCut: isCut
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(payload) {
            pasteboard.setData(data, forType: .fastSheetCells)
        }
        pasteboard.setString(plainText, forType: .string)

        if isCut { clearSelectedCells() }
    }

    private func pasteSelection() {
        guard let target = selection?.active else { return }
        let pasteboard = NSPasteboard.general

        if
            let data = pasteboard.data(forType: .fastSheetCells),
            let payload = try? JSONDecoder().decode(FastSheetClipboardPayload.self, from: data)
        {
            applyPaste(
                payload.values,
                at: target,
                source: CellPosition(row: payload.sourceRow, column: payload.sourceColumn),
                translateFormulas: !payload.isCut
            )
            if payload.isCut { pasteboard.clearContents() }
            return
        }

        guard var text = pasteboard.string(forType: .string) else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return }
        let values: [[String?]] = lines.map { line in
            line.components(separatedBy: "\t").map { $0.isEmpty ? nil : $0 }
        }
        applyPaste(values, at: target, source: nil, translateFormulas: false)
    }

    private func applyPaste(
        _ values: [[String?]],
        at target: CellPosition,
        source: CellPosition?,
        translateFormulas: Bool
    ) {
        guard !values.isEmpty else { return }
        let previous = workbook
        let rowDelta = source.map { target.row - $0.row } ?? 0
        let columnDelta = source.map { target.column - $0.column } ?? 0
        var lastRow = target.row
        var lastColumn = target.column

        for (rowOffset, rowValues) in values.enumerated() {
            let row = target.row + rowOffset
            guard row < SpreadsheetGridView.rowCount else { break }
            lastRow = row
            for (columnOffset, value) in rowValues.enumerated() {
                let column = target.column + columnOffset
                guard column < SpreadsheetGridView.columnCount else { break }
                lastColumn = max(lastColumn, column)
                let key = reference(row: row, column: column)
                guard let value, !value.isEmpty else {
                    workbook.sheets[workbook.activeSheetIndex].cells.removeValue(forKey: key)
                    continue
                }
                workbook.sheets[workbook.activeSheetIndex].cells[key] = translateFormulas
                    ? FormulaReferenceTranslator.translate(
                        value,
                        rowDelta: rowDelta,
                        columnDelta: columnDelta
                    )
                    : value
            }
        }

        guard workbook != previous else { return }
        let pastedSelection = CellSelection(
            anchor: CellPosition(row: lastRow, column: lastColumn),
            active: target
        )
        history.record(previous, selection: pastedSelection)
        persist()
        loadActiveSheet()
        selection = pastedSelection
        if let field = gridView.field(row: target.row, column: target.column) {
            selectedField = field
            view.window?.makeFirstResponder(field)
            scrollFieldToVisible(field)
        }
        applySelectionAppearance()
    }

    private func fillSelection(toWindowPoint point: NSPoint) {
        guard let sourceSelection = selection else { return }
        let local = gridView.convert(point, from: nil)
        let rawColumn = Int((local.x - SpreadsheetGridView.rowHeaderWidth) / SpreadsheetGridView.cellWidth)
        let rawRow = Int((local.y - SpreadsheetGridView.columnHeaderHeight) / SpreadsheetGridView.cellHeight)
        let targetRow = min(max(0, rawRow), SpreadsheetGridView.rowCount - 1)
        let targetColumn = min(max(0, rawColumn), SpreadsheetGridView.columnCount - 1)
        guard targetRow > sourceSelection.rows.upperBound || targetColumn > sourceSelection.columns.upperBound else { return }

        let previous = workbook
        let sourceRows = Array(sourceSelection.rows)
        let sourceColumns = Array(sourceSelection.columns)
        let sourceStartRow = sourceRows[0]
        let sourceStartColumn = sourceColumns[0]
        let targetRows: ClosedRange<Int> = sourceStartRow...max(sourceRows.last ?? 0, targetRow)
        let targetColumns: ClosedRange<Int> = sourceStartColumn...max(sourceColumns.last ?? 0, targetColumn)

        for row in targetRows {
            for column in targetColumns {
                guard !sourceSelection.contains(row: row, column: column) else { continue }
                let sourceRow = sourceRows[(row - sourceRows[0]) % sourceRows.count]
                let sourceColumn = sourceColumns[(column - sourceColumns[0]) % sourceColumns.count]
                let sourceKey = reference(row: sourceRow, column: sourceColumn)
                let targetKey = reference(row: row, column: column)
                guard let raw = activeSheet.cells[sourceKey], !raw.isEmpty else {
                    workbook.sheets[workbook.activeSheetIndex].cells.removeValue(forKey: targetKey)
                    continue
                }
                workbook.sheets[workbook.activeSheetIndex].cells[targetKey] = raw.hasPrefix("=")
                    ? FormulaReferenceTranslator.translate(
                        raw,
                        rowDelta: row - sourceRow,
                        columnDelta: column - sourceColumn
                    )
                    : raw
            }
        }

        guard workbook != previous else { return }
        let extendedSelection = CellSelection(
            anchor: CellPosition(row: targetRows.upperBound, column: targetColumns.upperBound),
            active: CellPosition(row: sourceRows[0], column: sourceColumns[0])
        )
        history.record(previous, selection: extendedSelection)
        persist()
        loadActiveSheet()
        selection = extendedSelection
        if let active = gridView.field(row: sourceRows[0], column: sourceColumns[0]) {
            selectedField = active
            view.window?.makeFirstResponder(active)
            scrollFieldToVisible(active)
        }
        applySelectionAppearance()
    }

    private func save(_ field: GridCellField) {
        let key = reference(row: field.row, column: field.column)
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = workbook
        if raw.isEmpty {
            workbook.sheets[workbook.activeSheetIndex].cells.removeValue(forKey: key)
        } else {
            workbook.sheets[workbook.activeSheetIndex].cells[key] = raw
        }
        guard workbook != previous else { return }
        let editedCell = CellSelection(
            anchor: CellPosition(row: field.row, column: field.column),
            active: CellPosition(row: field.row, column: field.column)
        )
        history.record(previous, selection: editedCell)
        persist()
    }

    private func undoWorkbookChange() {
        guard let entry = history.undo(current: workbook, selection: selection) else { return }
        var previous = entry.workbook
        previous.normalize()
        workbook = previous
        selection = entry.selection
        persist()
        loadActiveSheet()
        restoreSelectionFocus()
    }

    private func redoWorkbookChange() {
        guard let entry = history.redo(current: workbook, selection: selection) else { return }
        var next = entry.workbook
        next.normalize()
        workbook = next
        selection = entry.selection
        persist()
        loadActiveSheet()
        restoreSelectionFocus()
    }

    private func restoreSelectionFocus() {
        let position = selection?.active ?? CellPosition(row: 0, column: 0)
        guard let field = gridView.field(row: position.row, column: position.column) else { return }
        if selection == nil {
            selection = CellSelection(anchor: position, active: position)
        }
        selectedField = field
        view.window?.makeFirstResponder(field)
        scrollFieldToVisible(field)
        applySelectionAppearance()
    }

    private func moveSelection(
        from field: GridCellField,
        rowDelta: Int,
        columnDelta: Int,
        jump: Bool,
        extending: Bool
    ) {
        let destination = jump
            ? jumpDestination(from: field, rowDelta: rowDelta, columnDelta: columnDelta)
            : (
                row: min(max(0, field.row + rowDelta), SpreadsheetGridView.rowCount - 1),
                column: min(max(0, field.column + columnDelta), SpreadsheetGridView.columnCount - 1)
            )
        let row = destination.row
        let column = destination.column
        guard row != field.row || column != field.column else {
            if field.currentEditor() != nil {
                view.window?.makeFirstResponder(nil)
                DispatchQueue.main.async { [weak self, weak field] in
                    guard let self, let field else { return }
                    self.selectCell(field, extending: false)
                }
            } else {
                view.window?.makeFirstResponder(field)
            }
            return
        }
        view.window?.makeFirstResponder(nil)
        guard let next = gridView.field(row: row, column: column) else { return }
        DispatchQueue.main.async { [weak self, weak next] in
            guard let self, let next else { return }
            self.selectCell(next, extending: extending)
        }
    }

    private func extendSelection(toWindowPoint point: NSPoint) {
        let local = gridView.convert(point, from: nil)
        let rawColumn = Int((local.x - SpreadsheetGridView.rowHeaderWidth) / SpreadsheetGridView.cellWidth)
        let rawRow = Int((local.y - SpreadsheetGridView.columnHeaderHeight) / SpreadsheetGridView.cellHeight)
        let row = min(max(0, rawRow), SpreadsheetGridView.rowCount - 1)
        let column = min(max(0, rawColumn), SpreadsheetGridView.columnCount - 1)
        guard let field = gridView.field(row: row, column: column) else { return }
        selectCell(field, extending: true)
    }

    private func selectRow(_ row: Int) {
        guard let active = gridView.field(row: row, column: 0) else { return }
        selection = CellSelection(
            anchor: CellPosition(row: row, column: SpreadsheetGridView.columnCount - 1),
            active: CellPosition(row: row, column: 0)
        )
        selectedField = active
        view.window?.makeFirstResponder(active)
        applySelectionAppearance()
    }

    private func selectColumn(_ column: Int) {
        guard let active = gridView.field(row: 0, column: column) else { return }
        selection = CellSelection(
            anchor: CellPosition(row: SpreadsheetGridView.rowCount - 1, column: column),
            active: CellPosition(row: 0, column: column)
        )
        selectedField = active
        view.window?.makeFirstResponder(active)
        applySelectionAppearance()
    }

    private func selectAllCells() {
        guard let active = gridView.field(row: 0, column: 0) else { return }
        selection = CellSelection(
            anchor: CellPosition(
                row: SpreadsheetGridView.rowCount - 1,
                column: SpreadsheetGridView.columnCount - 1
            ),
            active: CellPosition(row: 0, column: 0)
        )
        selectedField = active
        view.window?.makeFirstResponder(active)
        applySelectionAppearance()
    }

    private func applySelectionAppearance() {
        let displaySelection = formulaReferenceSelection ?? selection
        for row in gridView.fields {
            for field in row {
                let position = CellPosition(row: field.row, column: field.column)
                let isSelected = selection?.contains(row: field.row, column: field.column) == true
                    || formulaReferenceSelection?.contains(row: field.row, column: field.column) == true
                let isActive = displaySelection?.active == position
                field.setSelectionState(selected: isSelected, active: isActive)
            }
        }
        gridView.updateHeaderSelection(displaySelection)
        gridView.updateFillHandle(formulaReferenceSelection == nil ? selection : nil)
        frozenColumnHeaders.update(selection: displaySelection)
        frozenRowHeaders.update(selection: displaySelection)
        refreshFormulaBar()
    }

    private func refreshFormulaBar() {
        guard formulaBar.currentEditor() == nil else { return }
        guard let active = selection?.active else {
            cellReferenceField.stringValue = ""
            formulaBar.stringValue = ""
            return
        }
        cellReferenceField.stringValue = reference(row: active.row, column: active.column)
        formulaBar.stringValue = activeSheet.cells[
            reference(row: active.row, column: active.column)
        ] ?? ""
    }

    private func jumpDestination(
        from field: GridCellField,
        rowDelta: Int,
        columnDelta: Int
    ) -> (row: Int, column: Int) {
        let startIsPopulated = isPopulated(row: field.row, column: field.column)
        var row = field.row
        var column = field.column

        while true {
            let nextRow = row + rowDelta
            let nextColumn = column + columnDelta
            guard (0..<SpreadsheetGridView.rowCount).contains(nextRow),
                  (0..<SpreadsheetGridView.columnCount).contains(nextColumn) else { break }
            let nextIsPopulated = isPopulated(row: nextRow, column: nextColumn)
            if startIsPopulated, !nextIsPopulated { break }
            row = nextRow
            column = nextColumn
            if !startIsPopulated, nextIsPopulated { break }
        }
        return (row, column)
    }

    private func isPopulated(row: Int, column: Int) -> Bool {
        let raw = activeSheet.cells[reference(row: row, column: column)] ?? ""
        return !raw.isEmpty
    }

    private func scrollFieldToVisible(_ field: GridCellField) {
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let fieldFrame = field.frame.insetBy(dx: -4, dy: -4)
        let origin = FrozenHeaderGeometry.scrollOrigin(revealing: fieldFrame, within: visible)
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshFrozenHeaders()
    }

    private func refreshFrozenHeaders() {
        frozenColumnHeaders.needsDisplay = true
        frozenRowHeaders.needsDisplay = true
    }

    private func persist() {
        workbook.normalize()
        saveWorkbook(workbook)
    }

    private func resetSelection() {
        selection = nil
        selectedField = nil
        applySelectionAppearance()
    }

    private func rebuildTabs() {
        for subview in tabs.arrangedSubviews {
            tabs.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for (index, sheet) in workbook.sheets.enumerated() {
            let button = NSButton(title: sheet.name, target: self, action: #selector(selectSheet(_:)))
            button.tag = index
            button.bezelStyle = index == workbook.activeSheetIndex ? .texturedRounded : .inline
            button.font = .systemFont(ofSize: 12, weight: index == workbook.activeSheetIndex ? .semibold : .regular)
            tabs.addArrangedSubview(button)

            if index == workbook.activeSheetIndex {
                let close = NSButton(title: "×", target: self, action: #selector(closeActiveSheet))
                close.isBordered = false
                close.toolTip = "Close sheet"
                tabs.addArrangedSubview(close)
            }
        }
    }

    @objc private func selectSheet(_ sender: NSButton) {
        guard workbook.sheets.indices.contains(sender.tag) else { return }
        view.window?.makeFirstResponder(nil)
        workbook.activeSheetIndex = sender.tag
        persist()
        resetSelection()
        loadActiveSheet(focusing: (0, 0))
    }

    @objc private func addSheet() {
        view.window?.makeFirstResponder(nil)
        history.record(workbook, selection: selection)
        workbook.sheets.append(Sheet(name: "Sheet \(workbook.sheets.count + 1)"))
        workbook.activeSheetIndex = workbook.sheets.count - 1
        persist()
        loadActiveSheet(focusing: (0, 0))
    }

    @objc private func closeActiveSheet() {
        view.window?.makeFirstResponder(nil)
        let sheet = activeSheet
        if !sheet.cells.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Close \(sheet.name)?"
            alert.informativeText = "This sheet contains data. Closing it will permanently remove the sheet."
            alert.addButton(withTitle: "Close Sheet")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        history.record(workbook, selection: selection)
        workbook.sheets.remove(at: workbook.activeSheetIndex)
        workbook.normalize()
        persist()
        resetSelection()
        loadActiveSheet(focusing: (0, 0))
    }
}

// MARK: - Hotkey and menu-bar application

final class HotkeyField: NSTextField {
    var capturedEvent: NSEvent?
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        capturedEvent = event
        stringValue = Self.display(event)
    }

    static func display(_ event: NSEvent) -> String {
        let flags = event.modifierFlags
        var result = ""
        if flags.contains(.command) { result += "⌘" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.shift) { result += "⇧" }
        result += (event.charactersIgnoringModifiers ?? "").uppercased()
        return result
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = WorkbookStore()
    private var statusItem: NSStatusItem!
    private var panel: FastSheetPanel?
    private var carbonHotKey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?

    private var hotkeyCode: UInt16 {
        UInt16(UserDefaults.standard.integer(forKey: "hotkeyCode"))
    }

    private var hotkeyModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "hotkeyModifiers")))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installDefaults()
        buildStatusItem()
        installCarbonHotkey()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.async { [weak self] in self?.showPanel() }
        }
    }

    private func installDefaults() {
        guard UserDefaults.standard.object(forKey: "hotkeyCode") == nil else { return }
        UserDefaults.standard.set(4, forKey: "hotkeyCode") // H
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: "hotkeyModifiers")
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "▦"
        statusItem.button?.font = .systemFont(ofSize: 17, weight: .medium)
        statusItem.button?.toolTip = "FastSheet"

        let menu = NSMenu()
        menu.addItem(menuItem("Show FastSheet", action: #selector(togglePanel)))
        menu.addItem(menuItem("Hotkey…", action: #selector(recordHotkey)))
        let login = menuItem("Launch at Login", action: #selector(toggleLaunchAtLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit FastSheet", action: #selector(quit)))
        statusItem.menu = menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePanel() {
        panel?.isVisible == true ? closePanel() : showPanel()
    }

    private func showPanel() {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let controller = SheetController(workbook: store.load()) { [weak self] workbook in
            self?.store.save(workbook)
        }
        let popup = FastSheetPanel(contentViewController: controller)
        popup.styleMask = [.borderless]
        popup.level = .floating
        popup.isFloatingPanel = true
        popup.hidesOnDeactivate = false
        popup.isReleasedWhenClosed = false
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.setContentSize(NSSize(width: 900, height: 500))
        popup.center()
        popup.onCancel = { [weak self] in self?.closePanel() }

        panel = popup
        NSApp.activate(ignoringOtherApps: true)
        popup.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        panel?.orderOut(nil)
    }

    @objc private func recordHotkey() {
        let alert = NSAlert()
        alert.messageText = "Set FastSheet Hotkey"
        alert.informativeText = "Press a key combination, then choose Save."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = HotkeyField(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        field.isEditable = false
        field.isSelectable = false
        field.alignment = .center
        field.stringValue = "Press a shortcut…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard
            alert.runModal() == .alertFirstButtonReturn,
            let event = field.capturedEvent,
            !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return }

        UserDefaults.standard.set(Int(event.keyCode), forKey: "hotkeyCode")
        UserDefaults.standard.set(
            Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue),
            forKey: "hotkeyModifiers"
        )
        installCarbonHotkey()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func installCarbonHotkey() {
        if let carbonHotKey {
            UnregisterEventHotKey(carbonHotKey)
            self.carbonHotKey = nil
        }

        if carbonHandler == nil {
            var specification = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let callback: EventHandlerUPP = { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.togglePanel() }
                return noErr
            }
            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                1,
                &specification,
                Unmanaged.passUnretained(self).toOpaque(),
                &carbonHandler
            )
        }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x46534854), id: 1)
        RegisterEventHotKey(
            UInt32(hotkeyCode),
            carbonModifiers(),
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        carbonHotKey = reference
    }

    private func carbonModifiers() -> UInt32 {
        var result: UInt32 = 0
        if hotkeyModifiers.contains(.command) { result |= UInt32(cmdKey) }
        if hotkeyModifiers.contains(.option) { result |= UInt32(optionKey) }
        if hotkeyModifiers.contains(.control) { result |= UInt32(controlKey) }
        if hotkeyModifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
