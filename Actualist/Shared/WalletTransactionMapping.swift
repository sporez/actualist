import Foundation

enum WalletTransactionStatus: String, Equatable, Sendable {
    case authorized
    case memo
    case pending
    case booked
    case rejected
}

enum WalletCreditDebitIndicator: String, Equatable, Sendable {
    case credit
    case debit
}

/// FinanceKit-free snapshot of the Wallet fields used for import.
struct WalletTransactionFields: Equatable, Sendable {
    var id: UUID
    var amount: Decimal
    var creditDebitIndicator: WalletCreditDebitIndicator
    var merchantName: String?
    var transactionDescription: String
    var transactionDate: Date
    var status: WalletTransactionStatus
}

struct WalletTransactionCandidate: Equatable, Sendable, Identifiable {
    var id: String { financialID }
    var financialID: String
    var payeeName: String
    var date: Date
    var amountMinorUnits: Int
    var isCleared: Bool
}

struct WalletTransactionImportResult: Equatable, Sendable {
    var importedCount: Int
    var duplicateCount: Int

    var summaryText: String {
        "Added \(Self.transactionPhrase(importedCount)), skipped \(Self.alreadyPhrase(duplicateCount))."
    }

    private static func transactionPhrase(_ count: Int) -> String {
        count == 1 ? "1 transaction" : "\(count) transactions"
    }

    private static func alreadyPhrase(_ count: Int) -> String {
        count == 1 ? "1 already on this account" : "\(count) already on this account"
    }
}

enum WalletTransactionMapper {
    private static let processorPrefixes = [
        "PAYPAL *",
        "SQ *",
        "TST *",
        "TST*",
        "SP "
    ]

    static func map(
        _ fields: WalletTransactionFields,
        currency: BudgetCurrency = .usd
    ) -> WalletTransactionCandidate? {
        guard fields.status != .rejected else {
            return nil
        }
        guard let amountMinorUnits = signedMinorUnits(
            amount: fields.amount,
            indicator: fields.creditDebitIndicator,
            currency: currency
        ) else {
            return nil
        }

        let rawPayee = rawPayeeName(from: fields)
        let payeeName = normalizePayee(rawPayee)
        return WalletTransactionCandidate(
            financialID: fields.id.uuidString.lowercased(),
            payeeName: payeeName.isEmpty ? "Unknown" : payeeName,
            date: fields.transactionDate,
            amountMinorUnits: amountMinorUnits,
            isCleared: fields.status == .booked
        )
    }

    static func normalizePayee(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()
        for prefix in processorPrefixes where lowered.hasPrefix(prefix.lowercased()) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        value = value.replacingOccurrences(
            of: #" #\d+$"#,
            with: "",
            options: .regularExpression
        )
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }
        return value.localizedCapitalized
    }

    static func draft(
        from candidate: WalletTransactionCandidate,
        accountID: String,
        sortOrder: Double
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: accountID,
            date: candidate.date,
            amountMinorUnits: candidate.amountMinorUnits,
            payeeID: nil,
            payeeName: candidate.payeeName,
            categoryID: nil,
            notes: nil,
            cleared: candidate.isCleared,
            isTransfer: false,
            importedPayee: candidate.payeeName,
            importedID: candidate.financialID,
            sortOrder: sortOrder
        )
    }

    static func applyingImportPreview(
        _ draft: TransactionDraft,
        _ preview: TransactionRulePreview
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: draft.accountID,
            date: draft.date,
            amountMinorUnits: draft.amountMinorUnits,
            payeeID: preview.payeeID ?? draft.payeeID,
            payeeName: draft.payeeName,
            categoryID: preview.splits.count >= 2 ? nil : (preview.categoryID ?? draft.categoryID),
            notes: preview.notes ?? draft.notes,
            cleared: preview.cleared ?? draft.cleared,
            isTransfer: draft.isTransfer,
            importedPayee: draft.importedPayee,
            importedID: draft.importedID,
            sortOrder: draft.sortOrder,
            reconciled: draft.reconciled,
            isParent: preview.splits.count >= 2 || draft.isParent,
            splits: preview.splits.count >= 2 ? preview.splits : draft.splits
        )
    }

    static func signedMinorUnits(
        amount: Decimal,
        indicator: WalletCreditDebitIndicator,
        currency: BudgetCurrency = .usd
    ) -> Int? {
        guard amount.isFinite,
              let value = currency.minorUnits(fromDisplay: amount.magnitude),
              value != 0 else {
            return nil
        }
        return indicator == .credit ? value : -value
    }

    private static func rawPayeeName(from fields: WalletTransactionFields) -> String {
        if let merchantName = fields.merchantName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !merchantName.isEmpty {
            return merchantName
        }
        return fields.transactionDescription
    }
}
