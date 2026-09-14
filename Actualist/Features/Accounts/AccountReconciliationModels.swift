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
            "Reconciliation is not available for this budget file."
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
    enum ValidationError: Error, Hashable, Sendable {
        case empty
        case invalid
        case tooManyFractionDigits
        case outOfRange
    }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(minorUnits: Int, currency: BudgetCurrency) {
        text = currency.editableAmountText(fromMinorUnits: minorUnits)
    }

    func minorUnits(
        currency: BudgetCurrency,
        locale: Locale = .current
    ) -> Result<Int, ValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator
        var normalized = trimmed
        if let groupingSeparator, groupingSeparator != decimalSeparator, !groupingSeparator.isEmpty {
            normalized = normalized.replacingOccurrences(of: groupingSeparator, with: "")
        }
        if decimalSeparator != "." {
            normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
        }

        var body = Substring(normalized)
        if body.first == "+" || body.first == "-" {
            body = body.dropFirst()
        }
        guard !body.isEmpty, body.first != "." else { return .failure(.invalid) }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              parts.first?.isEmpty == false else {
            return .failure(.invalid)
        }
        if parts.count == 2, parts[1].count > currency.decimalPlaces {
            return .failure(.tooManyFractionDigits)
        }
        guard let decimal = Decimal(
            string: normalized,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            return .failure(.invalid)
        }
        guard let value = currency.minorUnits(fromDisplay: decimal) else {
            return .failure(.outOfRange)
        }
        return .success(value)
    }
}
