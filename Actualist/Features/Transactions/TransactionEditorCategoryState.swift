import Foundation

struct TransactionSplitEditorRow: Identifiable, Hashable, Sendable {
    let id: String
    var transactionID: String?
    var categoryID: String
    var categoryName: String
    var amountDigits: String

    var amountCents: Int {
        Int(amountDigits) ?? 0
    }
}

struct TransactionSplitMismatch: Equatable, Sendable {
    let transactionTotal: Int
    let splitTotal: Int

    var difference: Int {
        transactionTotal - splitTotal
    }
}

enum TransactionSplitValidation: Equatable, Sendable {
    case valid
    case overflow
    case mismatch(TransactionSplitMismatch)
}

enum TransactionSplitEditorError: Error, Equatable {
    case amountOverflow
}

struct TransactionEditorCategoryState: Equatable, Sendable {
    private static let maximumAmountDigitCount = 16

    struct Category: Equatable, Sendable {
        let id: String?
        let name: String?
    }

    enum Selection: Equatable, Sendable {
        case single(Category)
        case selectingSplit(original: Category, rows: [TransactionSplitEditorRow])
        case split([TransactionSplitEditorRow])
    }

    private(set) var selection: Selection
    private(set) var pendingMismatch: TransactionSplitMismatch?

    init(
        categoryID: String? = nil,
        fallbackName: String? = nil,
        splitRows: [TransactionSplitEditorRow] = []
    ) {
        selection = splitRows.count >= 2
            ? .split(splitRows)
            : .single(Category(id: categoryID, name: fallbackName))
    }

    var selectedCategoryID: String? {
        switch selection {
        case .single(let category):
            category.id
        case .selectingSplit(let original, let rows):
            rows.count >= 2 ? nil : original.id
        case .split:
            nil
        }
    }

    var selectedCategoryFallbackName: String? {
        switch selection {
        case .single(let category):
            category.name
        case .selectingSplit(let original, let rows):
            rows.count >= 2 ? nil : original.name
        case .split:
            nil
        }
    }

    var splitRows: [TransactionSplitEditorRow] {
        switch selection {
        case .single:
            []
        case .selectingSplit(_, let rows), .split(let rows):
            rows
        }
    }

    var isSplit: Bool {
        splitRows.count >= 2
    }

    var isSelectingSplit: Bool {
        if case .selectingSplit = selection {
            return true
        }
        return false
    }

    var canRemoveSplitRow: Bool {
        isSplit
    }

    var checkedSplitTotalCents: Int? {
        var total = 0
        for row in splitRows {
            let result = total.addingReportingOverflow(row.amountCents)
            guard !result.overflow else {
                return nil
            }
            total = result.partialValue
        }
        return total
    }

    var splitTotalCents: Int {
        checkedSplitTotalCents ?? Int.max
    }

    func splitRemainingCents(transactionTotal: Int) -> Int {
        guard let checkedSplitTotalCents else {
            return 0
        }
        let difference = transactionTotal.subtractingReportingOverflow(checkedSplitTotalCents)
        return difference.overflow ? 0 : difference.partialValue
    }

    var summaryName: String? {
        let rows = splitRows
        guard rows.count >= 2 else {
            return selectedCategoryFallbackName
        }
        let names = rows.map(\.categoryName)
        return names.count <= 2 ? names.joined(separator: ", ") : "Split (\(names.count))"
    }

    mutating func clear() {
        selection = .single(Category(id: nil, name: nil))
        pendingMismatch = nil
    }

    mutating func discardSplitSelection() {
        switch selection {
        case .single:
            break
        case .selectingSplit(let original, _):
            selection = .single(original)
        case .split:
            selection = .single(Category(id: nil, name: nil))
        }
        pendingMismatch = nil
    }

    mutating func selectCategory(id: String, name: String?) {
        selection = .single(Category(id: id, name: name))
        pendingMismatch = nil
    }

    func containsSplitCategory(id: String) -> Bool {
        splitRows.contains { $0.categoryID == id }
    }

    mutating func beginSplitSelection() {
        pendingMismatch = nil
        switch selection {
        case .single(let category):
            let rows: [TransactionSplitEditorRow]
            if let categoryID = category.id {
                rows = [
                    TransactionSplitEditorRow(
                        id: categoryID,
                        transactionID: nil,
                        categoryID: categoryID,
                        categoryName: category.name ?? categoryID,
                        amountDigits: ""
                    )
                ]
            } else {
                rows = []
            }
            selection = .selectingSplit(original: category, rows: rows)
        case .split(let rows):
            selection = .selectingSplit(
                original: Category(id: nil, name: nil),
                rows: rows
            )
        case .selectingSplit:
            return
        }
    }

    mutating func toggleSplitCategory(id: String, name: String) {
        pendingMismatch = nil
        let original: Category
        var rows: [TransactionSplitEditorRow]

        switch selection {
        case .single(let category):
            original = category
            rows = []
        case .selectingSplit(let category, let existingRows):
            original = category
            rows = existingRows
        case .split(let existingRows):
            original = Category(id: nil, name: nil)
            rows = existingRows
        }

        if let index = rows.firstIndex(where: { $0.categoryID == id }) {
            rows.remove(at: index)
        } else {
            rows.append(
                TransactionSplitEditorRow(
                    id: id,
                    transactionID: nil,
                    categoryID: id,
                    categoryName: name,
                    amountDigits: ""
                )
            )
        }
        selection = .selectingSplit(original: original, rows: rows)
    }

    mutating func finalizeSplitSelection() {
        guard case .selectingSplit(let original, let rows) = selection else {
            return
        }
        if rows.count >= 2 {
            selection = .split(rows)
        } else if let row = rows.first {
            selection = .single(Category(id: row.categoryID, name: row.categoryName))
        } else {
            selection = .single(original)
        }
    }

    mutating func setSplitAmount(rowID: String, value: String) {
        updateRows { rows in
            guard let index = rows.firstIndex(where: { $0.id == rowID }) else {
                return
            }
            rows[index].amountDigits = Self.sanitizedAmountDigits(value)
        }
        pendingMismatch = nil
    }

    func formattedSplitAmount(rowID: String) -> String {
        guard let row = splitRows.first(where: { $0.id == rowID }), row.amountCents > 0 else {
            return ""
        }
        return "\(row.amountCents / 100).\(String(format: "%02d", row.amountCents % 100))"
    }

    mutating func removeSplit(rowID: String) {
        guard canRemoveSplitRow else {
            return
        }
        var rows = splitRows
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else {
            return
        }
        rows.remove(at: index)
        pendingMismatch = nil
        if rows.count == 1, let row = rows.first {
            selection = .single(Category(id: row.categoryID, name: row.categoryName))
        } else {
            selection = .split(rows)
        }
    }

    mutating func validate(transactionTotal: Int, submitsAsTransfer: Bool) -> TransactionSplitValidation {
        guard let checkedSplitTotalCents else {
            return .overflow
        }
        guard !submitsAsTransfer, isSplit, checkedSplitTotalCents != transactionTotal else {
            pendingMismatch = nil
            return .valid
        }
        let mismatch = TransactionSplitMismatch(
            transactionTotal: transactionTotal,
            splitTotal: checkedSplitTotalCents
        )
        pendingMismatch = mismatch
        return .mismatch(mismatch)
    }

    mutating func autoDistributeMismatch(transactionTotal: Int) throws {
        guard isSplit else {
            return
        }
        var rows = splitRows
        guard let checkedSplitTotalCents else {
            throw TransactionSplitEditorError.amountOverflow
        }
        let difference = transactionTotal.subtractingReportingOverflow(checkedSplitTotalCents)
        guard !difference.overflow else {
            throw TransactionSplitEditorError.amountOverflow
        }
        guard difference.partialValue != 0 else {
            pendingMismatch = nil
            return
        }
        let index = rows.lastIndex { $0.amountCents > 0 } ?? rows.indices.last
        guard let index else {
            return
        }
        let (adjustedAmount, overflow) = rows[index].amountCents.addingReportingOverflow(difference.partialValue)
        guard !overflow else {
            throw TransactionSplitEditorError.amountOverflow
        }
        rows[index].amountDigits = String(max(0, adjustedAmount))
        selection = .split(rows)
        pendingMismatch = nil
    }

    mutating func clearMismatch() {
        pendingMismatch = nil
    }

    mutating func applyRuleSplits(_ splits: [TransactionSplitDraft]) {
        let rows: [TransactionSplitEditorRow] = splits.enumerated().map { index, split in
            let categoryID = split.categoryID ?? "split-\(index)"
            return TransactionSplitEditorRow(
                id: split.id ?? categoryID,
                transactionID: split.id,
                categoryID: categoryID,
                categoryName: split.categoryName ?? categoryID,
                amountDigits: String(split.amountMinorUnits.magnitude)
            )
        }
        if rows.count >= 2 {
            selection = .split(rows)
            pendingMismatch = nil
        }
    }

    mutating func load(
        categoryID: String?,
        fallbackName: String?,
        subtransactions: [ActualTransaction]
    ) {
        let rows = subtransactions.compactMap { child -> TransactionSplitEditorRow? in
            guard let childCategoryID = child.category else {
                return nil
            }
            return TransactionSplitEditorRow(
                id: child.id ?? childCategoryID,
                transactionID: child.id,
                categoryID: childCategoryID,
                categoryName: childCategoryID,
                amountDigits: String((child.amount ?? 0).magnitude)
            )
        }
        selection = rows.count >= 2
            ? .split(rows)
            : .single(Category(id: categoryID, name: fallbackName))
        pendingMismatch = nil
    }

    mutating func resolveNames(_ namesByID: [String: String]) {
        switch selection {
        case .single(let category):
            guard let id = category.id, let name = namesByID[id] else {
                return
            }
            selection = .single(Category(id: id, name: name))
        case .selectingSplit(let original, var rows):
            rows = Self.resolvingNames(in: rows, namesByID: namesByID)
            let resolvedOriginal = original.id.flatMap { id in
                namesByID[id].map { Category(id: id, name: $0) }
            } ?? original
            selection = .selectingSplit(original: resolvedOriginal, rows: rows)
        case .split(let rows):
            selection = .split(Self.resolvingNames(in: rows, namesByID: namesByID))
        }
    }

    func splitDrafts(sign: Int) -> [TransactionSplitDraft] {
        guard isSplit else {
            return []
        }
        return splitRows.map { row in
            TransactionSplitDraft(
                id: row.transactionID,
                categoryID: row.categoryID,
                categoryName: row.categoryName,
                amountMinorUnits: row.amountCents * sign
            )
        }
    }

    private mutating func updateRows(_ update: (inout [TransactionSplitEditorRow]) -> Void) {
        switch selection {
        case .single:
            return
        case .selectingSplit(let original, var rows):
            update(&rows)
            selection = .selectingSplit(original: original, rows: rows)
        case .split(var rows):
            update(&rows)
            selection = .split(rows)
        }
    }

    private static func resolvingNames(
        in rows: [TransactionSplitEditorRow],
        namesByID: [String: String]
    ) -> [TransactionSplitEditorRow] {
        rows.map { row in
            var updated = row
            if let name = namesByID[row.categoryID] {
                updated.categoryName = name
            }
            return updated
        }
    }

    private static func sanitizedAmountDigits(_ value: String) -> String {
        let trimmed = value.filter(\.isNumber).drop(while: { $0 == "0" })
        return String(trimmed.prefix(maximumAmountDigitCount))
    }
}
