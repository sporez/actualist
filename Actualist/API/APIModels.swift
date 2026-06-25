import Foundation

struct APIDataResponse<Value: Decodable>: Decodable {
    let data: Value
}

struct APIGeneralResponseMessage: Decodable, Hashable, Sendable {
    let message: String?
}

struct APIBudgetMonthCategoryUpdatePayload: Encodable, Sendable {
    let category: Category

    init(budgeted: Int) {
        self.category = Category(budgeted: budgeted)
    }

    struct Category: Encodable, Sendable {
        let budgeted: Int
    }
}

struct APIBudgetCategoryTransferPayload: Encodable, Sendable {
    let categorytransfer: CategoryTransfer

    init(
        fromCategoryID: String?,
        toCategoryID: String?,
        amount: Int
    ) {
        categorytransfer = CategoryTransfer(
            fromCategoryID: fromCategoryID,
            toCategoryID: toCategoryID,
            amount: amount
        )
    }

    struct CategoryTransfer: Encodable, Sendable {
        let fromCategoryID: String?
        let toCategoryID: String?
        let amount: Int

        enum CodingKeys: String, CodingKey {
            case fromCategoryID = "fromCategoryId"
            case toCategoryID = "toCategoryId"
            case amount
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(fromCategoryID, forKey: .fromCategoryID)
            try container.encodeIfPresent(toCategoryID, forKey: .toCategoryID)
            try container.encode(amount, forKey: .amount)
        }
    }
}

struct APIBudgetTemplateApplyPayload: Encodable, Sendable {
    let mode: BudgetTemplateApplicationMode
    let categoryIDs: [String]?

    init(command: BudgetTemplateCommand) {
        mode = command.mode
        categoryIDs = command.categoryIDs.isEmpty ? nil : command.categoryIDs
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case categoryIDs = "categoryIds"
    }
}

struct APIBudgetTemplateApplyResult: Decodable, Hashable, Sendable {
    let type: String?
    let message: String?
    let pre: String?
    let sticky: Bool?
}

struct APIAccountCreatePayload: Encodable, Sendable {
    let account: Account

    init(name: String, offbudget: Bool) {
        account = Account(name: name, offbudget: offbudget)
    }

    struct Account: Encodable, Sendable {
        let name: String
        let offbudget: Bool
    }
}

struct APIAccountReconciliationPayload: Encodable, Sendable {
    let statementBalance: Int
}

struct APIAccountReconciliationResult: Decodable, Hashable, Sendable {
    let accountID: String
    let cutoffDate: String
    let statementBalance: Int
    let clearedBalance: Int
    let difference: Int
    let reconciled: Bool
    let updated: [String]

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case cutoffDate, statementBalance, clearedBalance, difference, reconciled, updated
    }
}

struct APITransactionRulesRunPayload: Encodable, Sendable {
    let transaction: APITransactionDraft
}

struct APITransactionMutationPayload: Encodable, Sendable {
    let learnCategories: Bool
    let runTransfers: Bool
    let transaction: APITransactionDraft

    init(
        transaction: APITransactionDraft,
        learnCategories: Bool = false,
        runTransfers: Bool = false
    ) {
        self.learnCategories = learnCategories
        self.runTransfers = runTransfers
        self.transaction = transaction
    }
}

struct APITransactionBatchUpdatePayload: Encodable, Sendable {
    let learnCategories: Bool
    let runTransfers: Bool
    let added: [APITransactionDraft]
    let updated: [APITransactionDraft]
    let deleted: [APITransactionDraft]

    init(
        added: [APITransactionDraft],
        updated: [APITransactionDraft] = [],
        deleted: [APITransactionDraft] = [],
        learnCategories: Bool = false,
        runTransfers: Bool = false
    ) {
        self.learnCategories = learnCategories
        self.runTransfers = runTransfers
        self.added = added
        self.updated = updated
        self.deleted = deleted
    }
}

struct APITransactionDraft: Encodable, Sendable {
    let id: String?
    let account: String
    let date: String
    let amount: Int
    let payee: String?
    let payeeName: String?
    let category: String?
    let notes: String?
    let cleared: Bool
    let subtransactions: [APITransactionDraft]

    init(
        id: String?,
        account: String,
        date: String,
        amount: Int,
        payee: String?,
        payeeName: String?,
        category: String?,
        notes: String?,
        cleared: Bool,
        subtransactions: [APITransactionDraft] = []
    ) {
        self.id = id
        self.account = account
        self.date = date
        self.amount = amount
        self.payee = payee
        self.payeeName = payeeName
        self.category = category
        self.notes = notes
        self.cleared = cleared
        self.subtransactions = subtransactions
    }

    enum CodingKeys: String, CodingKey {
        case id, account, date, amount, payee, category, notes, cleared
        case payeeName = "payee_name"
        case subtransactions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(account, forKey: .account)
        try container.encode(date, forKey: .date)
        try container.encode(amount, forKey: .amount)
        try container.encodeIfPresent(payee, forKey: .payee)
        try container.encodeIfPresent(payeeName, forKey: .payeeName)

        if let category, subtransactions.isEmpty {
            try container.encode(category, forKey: .category)
        } else {
            try container.encodeNil(forKey: .category)
        }

        if let notes {
            try container.encode(notes, forKey: .notes)
        } else {
            try container.encodeNil(forKey: .notes)
        }

        try container.encode(cleared, forKey: .cleared)

        if !subtransactions.isEmpty {
            try container.encode(subtransactions, forKey: .subtransactions)
        }
    }
}

struct APITransactionBatchUpdateResult: Decodable, Hashable, Sendable {
    let added: [ActualTransaction]
    let updated: [ActualTransaction]
    let deleted: [ActualTransaction]

    init(
        added: [ActualTransaction] = [],
        updated: [ActualTransaction] = [],
        deleted: [ActualTransaction] = []
    ) {
        self.added = added
        self.updated = updated
        self.deleted = deleted
    }

    enum CodingKeys: CodingKey {
        case added, updated, deleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        added = try container.decodeIfPresent([ActualTransaction].self, forKey: .added) ?? []
        updated = try container.decodeIfPresent([ActualTransaction].self, forKey: .updated) ?? []
        deleted = try container.decodeIfPresent([ActualTransaction].self, forKey: .deleted) ?? []
    }
}

struct APITransactionRulePreview: Decodable, Hashable, Sendable {
    let category: String?
    let notes: String?
}

struct ActualBudget: Codable, Identifiable, Hashable, Sendable {
    let budgetID: String?
    let cloudFileId: String?
    let groupId: String?
    let name: String
    let state: String?

    var id: String {
        syncID
    }

    var syncID: String {
        groupId ?? cloudFileId ?? budgetID ?? name
    }

    enum CodingKeys: String, CodingKey {
        case budgetID = "id"
        case cloudFileId, groupId, name, state
    }
}

struct ActualAccount: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let offbudget: Bool
    let closed: Bool
    let bankSyncLinked: Bool

    init(
        id: String,
        name: String,
        offbudget: Bool,
        closed: Bool,
        bankSyncLinked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.offbudget = offbudget
        self.closed = closed
        self.bankSyncLinked = bankSyncLinked
    }

    enum CodingKeys: String, CodingKey {
        case id, name, offbudget, closed, bankSyncLinked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        offbudget = try container.decode(Bool.self, forKey: .offbudget)
        closed = try container.decode(Bool.self, forKey: .closed)
        bankSyncLinked = try container.decodeIfPresent(Bool.self, forKey: .bankSyncLinked) ?? false
    }
}

struct AccountDisplay: Identifiable, Hashable, Sendable {
    let account: ActualAccount
    let balance: Int?

    var id: String { account.id }
}

struct BudgetMonth: Codable, Hashable, Sendable {
    let month: String
    let incomeAvailable: Int
    let lastMonthOverspent: Int
    let forNextMonth: Int
    let totalBudgeted: Int
    let toBudget: Int
    let fromLastMonth: Int
    let totalIncome: Int
    let totalSpent: Int
    let totalBalance: Int
    let categoryGroups: [BudgetMonthCategoryGroup]
}

struct APIBudgetMonthAlerts: Codable, Hashable, Sendable {
    let month: String
    let alerts: [APIBudgetMonthAlert]
}

struct APIBudgetMonthAlert: Codable, Hashable, Sendable {
    let kind: String
    let severity: String
    let title: String
    let amount: Int?
    let count: Int?
    let actionTitle: String?
}

struct BudgetMonthCategoryGroup: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isIncome: Bool
    let hidden: Bool?
    let budgeted: Int
    let spent: Int
    let balance: Int
    let categories: [BudgetMonthCategory]

    enum CodingKeys: String, CodingKey {
        case id, name, hidden, budgeted, spent, balance, categories
        case isIncome = "is_income"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isIncome = try container.decode(Bool.self, forKey: .isIncome)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        budgeted = try container.decodeIfPresent(Int.self, forKey: .budgeted) ?? 0
        spent = try container.decodeIfPresent(Int.self, forKey: .spent) ?? 0
        balance = try container.decodeIfPresent(Int.self, forKey: .balance) ?? 0
        categories = try container.decodeIfPresent([BudgetMonthCategory].self, forKey: .categories) ?? []
    }
}

struct BudgetMonthCategory: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isIncome: Bool
    let hidden: Bool?
    let groupID: String
    let budgeted: Int
    let spent: Int
    let balance: Int
    let carryover: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, hidden, budgeted, spent, balance, carryover
        case isIncome = "is_income"
        case groupID = "group_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isIncome = try container.decode(Bool.self, forKey: .isIncome)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        groupID = try container.decode(String.self, forKey: .groupID)
        budgeted = try container.decodeIfPresent(Int.self, forKey: .budgeted) ?? 0
        spent = try container.decodeIfPresent(Int.self, forKey: .spent) ?? 0
        balance = try container.decodeIfPresent(Int.self, forKey: .balance) ?? 0
        carryover = try container.decodeIfPresent(Bool.self, forKey: .carryover) ?? false
    }
}

struct ActualPayee: Codable, Identifiable, Hashable, Sendable {
    let id: String?
    let name: String
    let category: String?
    let transferAccount: String?

    enum CodingKeys: String, CodingKey {
        case id, name, category
        case transferAccount = "transfer_acct"
    }
}

struct ActualCategory: Codable, Identifiable, Hashable, Sendable {
    let id: String?
    let name: String
    let isIncome: Bool?
    let hidden: Bool?
    let groupID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, hidden
        case isIncome = "is_income"
        case groupID = "group_id"
    }
}

struct ActualTransaction: Codable, Identifiable, Hashable, Sendable {
    let id: String?
    let account: String
    let date: String
    let amount: Int?
    let payee: String?
    let payeeName: String?
    let importedPayee: String?
    let category: String?
    let notes: String?
    let cleared: FlexibleBool?
    let subtransactions: [ActualTransaction]
    let isParent: Bool
    let isChild: Bool
    let parentID: String?

    init(
        id: String?,
        account: String,
        date: String,
        amount: Int?,
        payee: String?,
        payeeName: String?,
        importedPayee: String?,
        category: String?,
        notes: String?,
        cleared: FlexibleBool?,
        subtransactions: [ActualTransaction] = [],
        isParent: Bool = false,
        isChild: Bool = false,
        parentID: String? = nil
    ) {
        self.id = id
        self.account = account
        self.date = date
        self.amount = amount
        self.payee = payee
        self.payeeName = payeeName
        self.importedPayee = importedPayee
        self.category = category
        self.notes = notes
        self.cleared = cleared
        self.subtransactions = subtransactions
        self.isParent = isParent
        self.isChild = isChild
        self.parentID = parentID
    }

    enum CodingKeys: String, CodingKey {
        case id, account, date, amount, payee, category, notes, cleared
        case payeeName = "payee_name"
        case importedPayee = "imported_payee"
        case subtransactions
        case isParent = "is_parent"
        case isChild = "is_child"
        case parentID = "parent_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        account = try container.decodeIfPresent(String.self, forKey: .account) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        amount = try container.decodeIfPresent(Int.self, forKey: .amount)
        payee = try container.decodeIfPresent(String.self, forKey: .payee)
        payeeName = try container.decodeIfPresent(String.self, forKey: .payeeName)
        importedPayee = try container.decodeIfPresent(String.self, forKey: .importedPayee)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        cleared = try container.decodeIfPresent(FlexibleBool.self, forKey: .cleared)
        subtransactions = try container.decodeIfPresent([ActualTransaction].self, forKey: .subtransactions) ?? []
        isParent = try container.decodeIfPresent(Bool.self, forKey: .isParent) ?? !subtransactions.isEmpty
        isChild = try container.decodeIfPresent(Bool.self, forKey: .isChild) ?? false
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
    }
}

enum FlexibleBool: Codable, Hashable, Sendable {
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .string((try? container.decode(String.self)) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let value): value
        case .string(let value): ["true", "cleared", "1"].contains(value.lowercased())
        }
    }
}
