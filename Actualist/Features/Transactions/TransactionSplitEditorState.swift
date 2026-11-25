import Foundation

struct TransactionSplitEditorRow: Identifiable, Hashable, Sendable {
    let id: String
    var transactionID: String?
    var amountMinorUnits: Int
    var categoryID: String?
    var categoryName: String?
    var payeeID: String?
    var payeeName: String?
    var notes: String?
    var isTransfer: Bool

    var amountDigits: String {
        let magnitude = abs(amountMinorUnits)
        return magnitude == 0 ? "" : String(magnitude)
    }

    var isInflow: Bool {
        amountMinorUnits > 0
    }

    var hasNoPayee: Bool {
        trimmed(payeeID) == nil && trimmed(payeeName) == nil
    }

    var displayPayeeName: String {
        if isTransfer, let payeeName, !payeeName.isEmpty {
            return "Transfer: \(payeeName)"
        }
        if let payeeName, !payeeName.isEmpty {
            return payeeName
        }
        return "(No payee)"
    }

    var displayCategoryName: String {
        if isTransfer {
            return "Account Transfer"
        }
        if let categoryName, !categoryName.isEmpty {
            return categoryName.actualistCategoryNameParts.name
        }
        return "Uncategorized"
    }

    var displayNotes: String {
        notes ?? ""
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

struct TransactionSplitEditorCollapse: Equatable, Sendable {
    let categoryID: String?
    let categoryName: String?
    let payeeID: String?
    let payeeName: String?
}

/// Lossless split-family editor value. Owns child identity, signed amounts,
/// nullable payee/category/notes, conversion/add/remove, remaining error, and
/// command projection. Views call mutating intents; they do not compute drafts.
struct TransactionSplitEditorState: Equatable, Sendable {
    private static let maximumAmountDigitCount = 16

    private(set) var children: [TransactionSplitEditorRow]
    private(set) var isActive: Bool
    private(set) var pendingMismatch: TransactionSplitMismatch?

    var isSplit: Bool { isActive }
    var splitRows: [TransactionSplitEditorRow] { children }
    var canRemoveSplitRow: Bool { isActive && !children.isEmpty }

    init(children: [TransactionSplitEditorRow] = [], isActive: Bool? = nil) {
        self.children = children
        self.isActive = isActive ?? !children.isEmpty
        pendingMismatch = nil
    }

    var checkedSplitTotalCents: Int? {
        Self.checkedSum(children.map(\.amountMinorUnits))
    }

    var splitTotalCents: Int {
        checkedSplitTotalCents ?? Int.max
    }

    func remainingCents(parentSignedAmount: Int) -> Int {
        guard let checkedSplitTotalCents else {
            return 0
        }
        let difference = parentSignedAmount.subtractingReportingOverflow(checkedSplitTotalCents)
        return difference.overflow ? 0 : difference.partialValue
    }

    func remainingStatusText(parentSignedAmount: Int, currency: BudgetCurrency) -> String {
        SplitRemainingPresentation.statusText(
            remaining: remainingCents(parentSignedAmount: parentSignedAmount),
            parentSignedAmount: parentSignedAmount,
            currency: currency
        )
    }

    mutating func load(from transaction: ActualTransaction) {
        guard transaction.isParent else {
            children = []
            isActive = false
            pendingMismatch = nil
            return
        }
        children = transaction.subtransactions.enumerated().map { index, child in
            TransactionSplitEditorRow(
                id: child.id ?? "split-child-\(index)",
                transactionID: child.id,
                amountMinorUnits: child.amount ?? 0,
                categoryID: child.category,
                categoryName: child.category,
                payeeID: child.payee,
                payeeName: child.payeeName,
                notes: child.notes,
                isTransfer: false
            )
        }
        isActive = true
        pendingMismatch = nil
    }

    mutating func convertToSplit(
        parentPayeeID: String?,
        parentPayeeName: String?,
        parentCategoryID: String?,
        parentCategoryName: String?
    ) {
        guard !isActive else { return }
        let inherited = TransactionSplitEditorRow(
            id: UUID().uuidString,
            transactionID: nil,
            amountMinorUnits: 0,
            categoryID: parentCategoryID,
            categoryName: parentCategoryName,
            payeeID: parentPayeeID,
            payeeName: parentPayeeName,
            notes: nil,
            isTransfer: false
        )
        children = [
            inherited,
            TransactionSplitEditorRow(
                id: UUID().uuidString,
                transactionID: nil,
                amountMinorUnits: 0,
                categoryID: parentCategoryID,
                categoryName: parentCategoryName,
                payeeID: parentPayeeID,
                payeeName: parentPayeeName,
                notes: nil,
                isTransfer: false
            )
        ]
        isActive = true
        pendingMismatch = nil
    }

    mutating func addChild(
        categoryID: String? = nil,
        categoryName: String? = nil,
        amountMinorUnits: Int = 0
    ) {
        guard isActive else { return }
        children.append(
            TransactionSplitEditorRow(
                id: UUID().uuidString,
                transactionID: nil,
                amountMinorUnits: amountMinorUnits,
                categoryID: categoryID,
                categoryName: categoryName,
                payeeID: nil,
                payeeName: nil,
                notes: nil,
                isTransfer: false
            )
        )
        pendingMismatch = nil
    }

    @discardableResult
    mutating func removeChild(id: String) -> TransactionSplitEditorCollapse? {
        guard canRemoveSplitRow, let index = children.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removingFromPair = children.count == 2
        children.remove(at: index)
        pendingMismatch = nil
        if children.isEmpty {
            isActive = false
            return TransactionSplitEditorCollapse(
                categoryID: nil,
                categoryName: nil,
                payeeID: nil,
                payeeName: nil
            )
        }
        if removingFromPair, let survivor = children.first {
            isActive = false
            children = []
            return TransactionSplitEditorCollapse(
                categoryID: survivor.categoryID,
                categoryName: survivor.categoryName,
                payeeID: survivor.payeeID,
                payeeName: survivor.payeeName
            )
        }
        return nil
    }

    mutating func setAmountDigits(id: String, value: String, defaultNegative: Bool) {
        guard let index = children.firstIndex(where: { $0.id == id }) else { return }
        let digits = Self.sanitizedAmountDigits(value)
        let magnitude = Int(digits) ?? 0
        let existing = children[index].amountMinorUnits
        let negative: Bool
        if existing == 0 {
            negative = defaultNegative
        } else {
            negative = existing < 0
        }
        children[index].amountMinorUnits = negative ? -magnitude : magnitude
        pendingMismatch = nil
    }

    mutating func toggleAmountSign(id: String) {
        guard let index = children.firstIndex(where: { $0.id == id }) else { return }
        children[index].amountMinorUnits = -children[index].amountMinorUnits
        pendingMismatch = nil
    }

    mutating func setCategory(id: String, categoryID: String?, name: String?) {
        guard let index = children.firstIndex(where: { $0.id == id }) else { return }
        guard !children[index].isTransfer else { return }
        children[index].categoryID = categoryID
        children[index].categoryName = name
        pendingMismatch = nil
    }

    mutating func setPayee(id: String, payeeID: String?, name: String?, isTransfer: Bool) {
        guard let index = children.firstIndex(where: { $0.id == id }) else { return }
        children[index].payeeID = payeeID
        children[index].payeeName = name
        children[index].isTransfer = isTransfer
        if isTransfer {
            children[index].categoryID = nil
            children[index].categoryName = "Account Transfer"
        }
        pendingMismatch = nil
    }

    mutating func setNotes(id: String, notes: String) {
        guard let index = children.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        children[index].notes = trimmed.isEmpty ? nil : notes
        pendingMismatch = nil
    }

    mutating func resolveNames(
        categoryNames: [String: String],
        payeeNames: [String: String],
        transferPayeeIDs: Set<String>
    ) {
        children = children.map { row in
            var updated = row
            if let categoryID = row.categoryID, let name = categoryNames[categoryID] {
                updated.categoryName = name
            }
            if let payeeID = row.payeeID {
                updated.isTransfer = transferPayeeIDs.contains(payeeID)
                if let name = payeeNames[payeeID] {
                    updated.payeeName = name
                }
                if updated.isTransfer {
                    updated.categoryName = "Account Transfer"
                }
            }
            return updated
        }
    }

    mutating func applyRuleSplits(_ splits: [TransactionSplitDraft]) {
        guard !splits.isEmpty else { return }
        children = splits.enumerated().map { index, split in
            let payeeID: String?
            switch split.payeeID {
            case .omitted:
                payeeID = nil
            case .value(let value):
                payeeID = value
            }
            let notes: String?
            switch split.notes {
            case .omitted:
                notes = nil
            case .value(let value):
                notes = value
            }
            return TransactionSplitEditorRow(
                id: split.id ?? "split-\(index)",
                transactionID: split.id,
                amountMinorUnits: split.amountMinorUnits,
                categoryID: split.categoryID,
                categoryName: split.categoryName ?? split.categoryID,
                payeeID: payeeID,
                payeeName: nil,
                notes: notes,
                isTransfer: false
            )
        }
        isActive = true
        pendingMismatch = nil
    }

    mutating func discard() {
        children = []
        isActive = false
        pendingMismatch = nil
    }

    mutating func replaceChildren(_ rows: [TransactionSplitEditorRow]) {
        children = rows
        isActive = !rows.isEmpty
        pendingMismatch = nil
    }

    func formattedAmount(rowID: String, currency: BudgetCurrency) -> String {
        guard let row = children.first(where: { $0.id == rowID }), row.amountMinorUnits != 0 else {
            return ""
        }
        return currency.editableAmountText(fromMinorUnits: abs(row.amountMinorUnits))
    }

    func splitDrafts() -> [TransactionSplitDraft] {
        guard isActive else { return [] }
        return children.enumerated().map { index, row in
            TransactionSplitDraft(
                id: row.transactionID,
                categoryID: row.categoryID,
                categoryName: row.categoryName,
                amountMinorUnits: row.amountMinorUnits,
                payeeID: .value(row.payeeID),
                notes: .value(row.notes),
                sortOrder: row.transactionID == nil ? .value(Double(-(index + 1))) : .omitted
            )
        }
    }

    mutating func validate(parentSignedAmount: Int) -> TransactionSplitValidation {
        guard isActive else {
            pendingMismatch = nil
            return .valid
        }
        guard let checkedSplitTotalCents else {
            return .overflow
        }
        pendingMismatch = nil
        if checkedSplitTotalCents != parentSignedAmount {
            pendingMismatch = TransactionSplitMismatch(
                transactionTotal: parentSignedAmount,
                splitTotal: checkedSplitTotalCents
            )
        }
        return .valid
    }

    mutating func autoDistribute(parentSignedAmount: Int) throws {
        guard isActive else { return }
        guard let checkedSplitTotalCents else {
            throw TransactionSplitEditorError.amountOverflow
        }
        let difference = parentSignedAmount.subtractingReportingOverflow(checkedSplitTotalCents)
        guard !difference.overflow else {
            throw TransactionSplitEditorError.amountOverflow
        }
        guard difference.partialValue != 0 else {
            pendingMismatch = nil
            return
        }
        guard !children.isEmpty else { return }
        guard let amounts = Self.distributedAmounts(
            children.map(\.amountMinorUnits),
            parentSignedAmount: parentSignedAmount,
            remainder: difference.partialValue
        ) else {
            throw TransactionSplitEditorError.amountOverflow
        }
        for index in children.indices {
            children[index].amountMinorUnits = amounts[index]
        }
        pendingMismatch = nil
    }

    /// Actual's split Distribute (`onDistributeRemainder` in `TransactionsTable`):
    /// empty splits share the remainder evenly, the earlier ones taking the odd
    /// cents. With none empty, each split grows in proportion to its amount and
    /// the rounding cents go to the splits in order. Nil on overflow.
    private static func distributedAmounts(_ amounts: [Int], parentSignedAmount: Int, remainder: Int) -> [Int]? {
        var result = amounts
        let emptyIndices = amounts.indices.filter { amounts[$0] == 0 }
        if !emptyIndices.isEmpty {
            let count = emptyIndices.count
            // Math.floor rounds toward negative infinity; Swift's division truncates.
            let share = remainder / count - (remainder % count < 0 ? 1 : 0)
            var oddCents = remainder - share * count
            for index in emptyIndices {
                result[index] = share + (oddCents > 0 ? 1 : 0)
                oddCents -= oddCents > 0 ? 1 : 0
            }
            return result
        }

        guard let total = checkedSum(amounts), total != 0 else {
            // Splits that cancel out leave Actual dividing by zero, and its
            // rounding loop never ends; the last split takes the difference.
            guard let last = amounts.indices.last else { return nil }
            let (adjusted, overflow) = amounts[last].addingReportingOverflow(remainder)
            guard !overflow else { return nil }
            result[last] = adjusted
            return result
        }
        for index in amounts.indices {
            let scaled = (Double(amounts[index]) / Double(total) * Double(remainder)).rounded(.down)
            guard let share = Int(exactly: scaled) else { return nil }
            let (adjusted, overflow) = amounts[index].addingReportingOverflow(share)
            guard !overflow else { return nil }
            result[index] = adjusted
        }
        guard let distributed = checkedSum(result) else { return nil }
        let (leftover, overflow) = parentSignedAmount.subtractingReportingOverflow(distributed)
        guard !overflow, leftover.magnitude <= UInt(result.count) * 2 else { return nil }
        var cents = leftover
        var index = 0
        while cents != 0 {
            let step = cents > 0 ? 1 : -1
            result[index % result.count] += step
            cents -= step
            index += 1
        }
        return result
    }

    private static func checkedSum(_ amounts: [Int]) -> Int? {
        var total = 0
        for amount in amounts {
            let (sum, overflow) = total.addingReportingOverflow(amount)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    mutating func clearMismatch() {
        pendingMismatch = nil
    }

    /// Maps any Unicode decimal digit (Arabic-Indic, Devanagari, fullwidth) to
    /// ASCII, drops everything else (including `①`-style non-decimal digits and
    /// separators), strips leading zeros, and caps the length.
    static func sanitizedAmountDigits(_ value: String) -> String {
        var digits = ""
        for scalar in value.unicodeScalars where scalar.properties.numericType == .decimal {
            guard let number = scalar.properties.numericValue,
                  let digit = Int(exactly: number), (0...9).contains(digit) else { continue }
            digits.append(String(digit))
        }
        return String(digits.drop(while: { $0 == "0" }).prefix(maximumAmountDigitCount))
    }
}

private func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
