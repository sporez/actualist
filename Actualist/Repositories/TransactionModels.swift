import Foundation

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
    let isTransfer: Bool
    var importedPayee: String? = nil
    var importedID: String? = nil
    var sortOrder: Double? = nil
    var reconciled = false
    var isParent = false
    var splits: [TransactionSplitDraft] = []
    var scheduleID: String? = nil

    var month: YearMonth {
        YearMonth(date: date)
    }

    var isSplit: Bool {
        !splits.isEmpty
    }
}

struct TransactionSplitDraft: Hashable, Sendable, Identifiable {
    let id: String?
    let categoryID: String?
    let categoryName: String?
    let amountMinorUnits: Int
    var payeeID: SplitOptionalField<String> = .omitted
    var notes: SplitOptionalField<String> = .omitted
    var sortOrder: SplitOptionalField<Double> = .omitted

    var stableID: String {
        id ?? categoryID ?? categoryName ?? "\(amountMinorUnits)"
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
    let accountID: String?
    let payeeID: String?
    let amountMinorUnits: Int?
    let date: Date?
    let cleared: Bool?
    let scheduleID: String?
    let deletesTransaction: Bool
    let splits: [TransactionSplitDraft]

    init(
        categoryID: String?,
        notes: String?,
        accountID: String? = nil,
        payeeID: String? = nil,
        amountMinorUnits: Int? = nil,
        date: Date? = nil,
        cleared: Bool? = nil,
        scheduleID: String? = nil,
        deletesTransaction: Bool = false,
        splits: [TransactionSplitDraft] = []
    ) {
        self.categoryID = categoryID
        self.notes = notes
        self.accountID = accountID
        self.payeeID = payeeID
        self.amountMinorUnits = amountMinorUnits
        self.date = date
        self.cleared = cleared
        self.scheduleID = scheduleID
        self.deletesTransaction = deletesTransaction
        self.splits = splits
    }
}
