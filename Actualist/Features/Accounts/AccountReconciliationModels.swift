import Foundation

enum AccountReconciliationUnavailableReason: Hashable, Sendable {
    case accountNotFound
    case missingAccountSchema
    case missingTransactionSchema
    case missingLastReconciledColumn

    var message: String {
        switch self {
        case .accountNotFound:
            "This account is no longer available."
        case .missingAccountSchema, .missingTransactionSchema, .missingLastReconciledColumn:
            "Reconciliation is not available for this budget."
        }
    }
}

enum AccountReconciliationCapability: Hashable, Sendable {
    case available
    case unavailable(AccountReconciliationUnavailableReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

struct AccountReconciliationSnapshot: Hashable, Sendable {
    let accountID: String
    let accountName: String
    let workingBalance: Int
    let clearedBalance: Int
    let lastSyncedBalance: Int?
    let lastReconciledMilliseconds: Int64?
    let capability: AccountReconciliationCapability

    var lastReconciledAt: Date? {
        lastReconciledMilliseconds.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
        }
    }
}

struct AccountReconciliationCalculation: Hashable, Sendable {
    let targetBalance: Int
    let clearedBalance: Int
    let difference: Int?

    init(targetBalance: Int, clearedBalance: Int) {
        self.targetBalance = targetBalance
        self.clearedBalance = clearedBalance
        let result = targetBalance.subtractingReportingOverflow(clearedBalance)
        difference = result.overflow ? nil : result.partialValue
    }

    var isBalanced: Bool { difference == 0 }
    var canCreateAdjustment: Bool { difference.map { $0 != 0 } ?? false }
    var canLockTransactions: Bool { difference == 0 }
}

enum AccountReconciliationCommandError: Error, Hashable, Sendable {
    case unavailable(AccountReconciliationUnavailableReason)
    case differenceOverflow
    case alreadyBalanced
    case balanceChanged
    case transactionNotFound
}

struct AccountReconciliationMutationResult: Hashable, Sendable {
    let snapshot: AccountReconciliationSnapshot
    let changed: ChangedResources
}

struct AccountReconciliationDatabaseWrite: Hashable, Sendable {
    let changed: ChangedResources
    let committed: Bool
}

struct AccountReconciliationAmountInput: Hashable, Sendable {
    typealias ValidationError = MoneyInputError

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(minorUnits: Int, currency: BudgetCurrency) {
        text = BudgetMoneyInputFormat.editText(minorUnits: minorUnits, currency: currency)
    }

    var isNegative: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
    }

    var magnitudeText: String {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.first == "+" || body.first == "-" {
            body = body.dropFirst()
        }
        return String(body)
    }

    mutating func setMagnitudeText(_ value: String) {
        let negative = isNegative
        var body = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.first == "+" || body.first == "-" {
            body = body.dropFirst()
        }
        let magnitude = String(body)
        if negative {
            text = magnitude.isEmpty ? "-" : "-" + magnitude
        } else {
            text = magnitude
        }
    }

    mutating func toggleSign() {
        if isNegative {
            text = magnitudeText
        } else {
            let magnitude = magnitudeText
            text = magnitude.isEmpty ? "-" : "-" + magnitude
        }
    }

    /// The typed balance the way Actual's reconcile field reads it (`fromEdit`).
    func minorUnits(currency: BudgetCurrency) -> Result<Int, ValidationError> {
        BudgetMoneyInputFormat.minorUnits(text, currency: currency)
    }
}
