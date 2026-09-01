import Foundation

/// Lookup tables needed to project a transaction row without owning store state.
struct TransactionRowLookup: Equatable, Sendable {
    var payeeNames: [String: String] = [:]
    var categoryNames: [String: String] = [:]
    var transferPayeeIDs: Set<String> = []
    var transferAccountIDsByPayeeID: [String: String] = [:]
    var offBudgetAccountIDs: Set<String> = []
}

/// Pure Actual 26.8.1 row/family presentation. Views render this value; they
/// do not recompute payee fallbacks, split identity, or money.
struct TransactionRowSemantics: Equatable, Hashable, Sendable {
    enum PayeeKind: Equatable, Hashable, Sendable {
        case named
        case noPayee
        case unresolved
        case splitNoPayee
    }

    enum Status: Equatable, Hashable, Sendable {
        case uncleared
        case cleared
        case reconciled
    }

    enum TransferDirection: Equatable, Hashable, Sendable {
        case inflow
        case outflow
    }

    let payeeKind: PayeeKind
    let payeeText: String
    let categoryText: String
    let isParent: Bool
    let isChild: Bool
    let status: Status
    let notes: String?
    let errorDifference: Int?
    /// Remainder after the expense-parent display flip. Positive is left,
    /// negative is over. Nil when there is no visible mismatch.
    let errorDisplayedCents: Int?
    let transferDirection: TransferDirection?

    var isSplitFamily: Bool { isParent || isChild }
    var isPlaceholderPayee: Bool {
        switch payeeKind {
        case .noPayee, .unresolved, .splitNoPayee:
            true
        case .named:
            false
        }
    }

    static func project(
        _ transaction: ActualTransaction,
        lookup: TransactionRowLookup,
        privacyEnabled: Bool = false
    ) -> TransactionRowSemantics {
        let payee = payeeProjection(for: transaction, lookup: lookup)
        let category = categoryText(for: transaction, lookup: lookup)
        let notes = trimmed(transaction.notes)
        let errorDifference = transaction.isParent ? transaction.error?.difference : nil
        let errorDisplayedCents: Int?
        if let errorDifference, errorDifference != 0 {
            errorDisplayedCents = SplitRemainingPresentation.displayedCents(
                remaining: errorDifference,
                parentSignedAmount: transaction.amount ?? 0
            )
        } else {
            errorDisplayedCents = nil
        }
        let semantics = TransactionRowSemantics(
            payeeKind: payee.kind,
            payeeText: payee.text,
            categoryText: category,
            isParent: transaction.isParent,
            isChild: transaction.isChild,
            status: status(for: transaction),
            notes: notes,
            errorDifference: errorDifference,
            errorDisplayedCents: errorDisplayedCents,
            transferDirection: transferDirection(for: transaction, lookup: lookup)
        )
        guard privacyEnabled else {
            return semantics
        }
        return semantics.privatized(transactionID: transaction.rowID)
    }

    private func privatized(transactionID: String) -> TransactionRowSemantics {
        TransactionRowSemantics(
            payeeKind: payeeKind,
            payeeText: isPlaceholderPayee
                ? payeeText
                : PrivacyDisplay.name(for: .payee, seed: "payee-\(transactionID)"),
            categoryText: isParent
                ? categoryText
                : PrivacyDisplay.name(for: .category, seed: "category-\(transactionID)"),
            isParent: isParent,
            isChild: isChild,
            status: status,
            notes: notes.map { _ in
                PrivacyDisplay.name(for: .payee, seed: "notes-\(transactionID)")
            },
            errorDifference: errorDifference,
            errorDisplayedCents: errorDisplayedCents,
            transferDirection: transferDirection
        )
    }

    private static func payeeProjection(
        for transaction: ActualTransaction,
        lookup: TransactionRowLookup
    ) -> (kind: PayeeKind, text: String) {
        if transaction.isParent {
            return splitParentPayee(for: transaction, lookup: lookup)
        }
        return ordinaryPayee(for: transaction, lookup: lookup, allowImportedFallback: true)
    }

    private static func splitParentPayee(
        for transaction: ActualTransaction,
        lookup: TransactionRowLookup
    ) -> (kind: PayeeKind, text: String) {
        var counts: [String: Int] = [:]
        var mostCommonChild: ActualTransaction?
        var maxCount = 0
        for child in transaction.subtransactions {
            guard let payeeID = trimmed(child.payee) else { continue }
            let next = (counts[payeeID] ?? 0) + 1
            counts[payeeID] = next
            if next > maxCount {
                maxCount = next
                mostCommonChild = child
            }
        }

        guard let mostCommonChild else {
            return (.splitNoPayee, "Split (no payee)")
        }

        let resolved = ordinaryPayee(
            for: mostCommonChild,
            lookup: lookup,
            allowImportedFallback: false
        )
        guard resolved.kind == .named else {
            return (.splitNoPayee, "Split (no payee)")
        }

        let hiddenCount = max(0, counts.count - 1)
        let text = hiddenCount > 0
            ? "\(resolved.text) (+\(hiddenCount) more)"
            : resolved.text
        return (.named, text)
    }

    private static func ordinaryPayee(
        for transaction: ActualTransaction,
        lookup: TransactionRowLookup,
        allowImportedFallback: Bool
    ) -> (kind: PayeeKind, text: String) {
        if let name = trimmed(transaction.payeeName) {
            return (.named, name)
        }
        if let payeeID = trimmed(transaction.payee) {
            if let name = lookup.payeeNames[payeeID], let trimmedName = trimmed(name) {
                return (.named, trimmedName)
            }
            return (.unresolved, "Unknown Payee")
        }
        if allowImportedFallback, let imported = trimmed(transaction.importedPayee) {
            return (.named, imported)
        }
        return (.noPayee, "(No payee)")
    }

    private static func categoryText(
        for transaction: ActualTransaction,
        lookup: TransactionRowLookup
    ) -> String {
        if lookup.offBudgetAccountIDs.contains(transaction.account) {
            return "Off budget"
        }
        if transaction.isParent {
            return "Split"
        }
        if let payee = transaction.payee, lookup.transferPayeeIDs.contains(payee) {
            if let destinationAccountID = lookup.transferAccountIDsByPayeeID[payee],
               lookup.offBudgetAccountIDs.contains(destinationAccountID) {
                if let category = transaction.category {
                    return lookup.categoryNames[category] ?? "Uncategorized"
                }
                return "Uncategorized"
            }
            return "Account Transfer"
        }
        guard let category = transaction.category else {
            return "Uncategorized"
        }
        return lookup.categoryNames[category] ?? "Uncategorized"
    }

    private static func status(for transaction: ActualTransaction) -> Status {
        if transaction.reconciled {
            return .reconciled
        }
        if transaction.cleared?.boolValue == true {
            return .cleared
        }
        return .uncleared
    }

    private static func transferDirection(
        for transaction: ActualTransaction,
        lookup: TransactionRowLookup
    ) -> TransferDirection? {
        guard let payee = transaction.payee, lookup.transferPayeeIDs.contains(payee) else {
            return nil
        }
        return (transaction.amount ?? 0) > 0 ? .inflow : .outflow
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum TransactionPayeePresentation {
    static func name(
        for transaction: ActualTransaction,
        payeeNames: [String: String]
    ) -> String {
        TransactionRowSemantics.project(
            transaction,
            lookup: TransactionRowLookup(payeeNames: payeeNames)
        ).payeeText
    }
}

enum TransactionCategoryPresentation {
    static func names(
        for transaction: ActualTransaction,
        categoryNames: [String: String],
        transferPayeeIDs: Set<String>,
        transferAccountIDsByPayeeID: [String: String] = [:],
        offBudgetAccountIDs: Set<String>
    ) -> [String] {
        [
            TransactionRowSemantics.project(
                transaction,
                lookup: TransactionRowLookup(
                    categoryNames: categoryNames,
                    transferPayeeIDs: transferPayeeIDs,
                    transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
                    offBudgetAccountIDs: offBudgetAccountIDs
                )
            ).categoryText
        ]
    }
}
