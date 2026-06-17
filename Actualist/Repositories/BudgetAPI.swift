import Foundation

typealias BudgetAccount = ActualAccount

struct YearMonth: Hashable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(date: Date) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        self.rawValue = String(format: "%04d-%02d", components.year ?? 1970, components.month ?? 1)
    }
}

struct TransactionDraft: Hashable, Sendable {
    let accountID: String
    let date: Date
    let amountMinorUnits: Int
    let payeeID: String?
    let payeeName: String
    let categoryID: String?
    let notes: String?
    let cleared: Bool

    var month: YearMonth {
        YearMonth(date: date)
    }
}

struct TransactionMutationResult: Hashable, Sendable {
    let ok: Bool
    let changed: ChangedResources
}

struct ChangedResources: Hashable, Sendable {
    let accounts: [String]
    let months: [String]
    let transactions: [String]
}

struct TransactionRulePreview: Hashable, Sendable {
    let categoryID: String?
    let notes: String?
}
