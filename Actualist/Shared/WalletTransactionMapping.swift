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
    /// FinanceKit's account ID, lowercased. Like the transaction ID it is
    /// assigned per device, so it keys only device-local links.
    var walletAccountID: String = ""
}

struct WalletTransactionCandidate: Equatable, Sendable, Identifiable {
    var id: String { financialID }
    var financialID: String
    /// Raw FinanceKit merchant/description text for `imported_payee` rules.
    var importedPayee: String?
    /// Presentation/payee-lookup value after the existing Wallet cleanup.
    var payeeName: String
    var date: Date
    var amountMinorUnits: Int
    var isCleared: Bool
}

struct WalletTransactionImportResult: Equatable, Sendable {
    var addedCount: Int
    /// Already on the account: matched by Wallet ID, or by amount and date when
    /// Wallet gave the transaction a new ID. A match may fill in the row.
    var matchedCount: Int
    /// Not written: removed or moved to another account by a rule, or deleted
    /// earlier with the account set not to bring deleted rows back.
    var skippedCount: Int = 0

    var summaryText: String {
        let summary = "Added \(Self.transactionPhrase(addedCount)), found \(Self.alreadyPhrase(matchedCount))."
        return skippedCount == 0 ? summary : summary + " Skipped \(skippedCount)."
    }

    private static func transactionPhrase(_ count: Int) -> String {
        count == 1 ? "1 transaction" : "\(count) transactions"
    }

    private static func alreadyPhrase(_ count: Int) -> String {
        "\(count) already on this account"
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payeeName = normalizePayee(rawPayee)
        return WalletTransactionCandidate(
            financialID: fields.id.uuidString.lowercased(),
            importedPayee: rawPayee.isEmpty ? nil : rawPayee,
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

    /// The shared import step's candidate. The day is the device's local
    /// calendar day, the day Wallet import has always written.
    static func reconcileCandidate(
        from candidate: WalletTransactionCandidate,
        payeeID: String?,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> BankSyncReconciliation.Candidate {
        BankSyncReconciliation.Candidate(
            financialID: candidate.financialID,
            dayID: ActualDateOnly.dayID(from: candidate.date, timeZone: timeZone)
                .replacingOccurrences(of: "-", with: ""),
            amountMinorUnits: candidate.amountMinorUnits,
            payeeID: payeeID,
            payeeName: candidate.payeeName,
            notes: nil,
            categoryID: nil,
            cleared: candidate.isCleared,
            importedPayee: candidate.importedPayee
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
