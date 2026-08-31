import Foundation

struct AccountReconciliationResult: Hashable, Sendable {
    let accountID: String
    let cutoffDate: String
    let statementBalance: Int
    let clearedBalance: Int
    let difference: Int
    let reconciled: Bool
    let updated: [String]
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
    let bankSyncStatus: String?
    let accountGroupId: String?

    init(
        id: String,
        name: String,
        offbudget: Bool,
        closed: Bool,
        bankSyncLinked: Bool = false,
        bankSyncStatus: String? = nil,
        accountGroupId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.offbudget = offbudget
        self.closed = closed
        self.bankSyncLinked = bankSyncLinked
        self.bankSyncStatus = bankSyncStatus
        self.accountGroupId = accountGroupId
    }

    enum CodingKeys: String, CodingKey {
        case id, name, offbudget, closed, bankSyncLinked, bankSyncStatus, accountGroupId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        offbudget = try container.decode(Bool.self, forKey: .offbudget)
        closed = try container.decode(Bool.self, forKey: .closed)
        bankSyncLinked = try container.decodeIfPresent(Bool.self, forKey: .bankSyncLinked) ?? false
        bankSyncStatus = try container.decodeIfPresent(String.self, forKey: .bankSyncStatus)
        accountGroupId = try container.decodeIfPresent(String.self, forKey: .accountGroupId)
    }

    var bankSyncState: ActualBankSyncState? {
        guard bankSyncLinked else {
            return nil
        }

        switch bankSyncStatus {
        case "pending", "sync-requested":
            return .pending
        case nil, "ok":
            return .healthy
        default:
            // Unknown durable statuses are failures too.
            return .failed
        }
    }
}

enum ActualBankSyncState: Hashable, Sendable {
    case healthy
    case pending
    case failed
}

struct ActualAccountGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let sortOrder: Double
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

struct BudgetMonthAlert: Codable, Hashable, Sendable {
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

    init(
        id: String,
        name: String,
        isIncome: Bool,
        hidden: Bool?,
        budgeted: Int,
        spent: Int,
        balance: Int,
        categories: [BudgetMonthCategory]
    ) {
        self.id = id
        self.name = name
        self.isIncome = isIncome
        self.hidden = hidden
        self.budgeted = budgeted
        self.spent = spent
        self.balance = balance
        self.categories = categories
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
    let hasTemplateDefinition: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, hidden, budgeted, spent, balance, carryover, hasTemplateDefinition
        case isIncome = "is_income"
        case groupID = "group_id"
    }

    init(
        id: String,
        name: String,
        isIncome: Bool,
        hidden: Bool?,
        groupID: String,
        budgeted: Int,
        spent: Int,
        balance: Int,
        carryover: Bool,
        hasTemplateDefinition: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isIncome = isIncome
        self.hidden = hidden
        self.groupID = groupID
        self.budgeted = budgeted
        self.spent = spent
        self.balance = balance
        self.carryover = carryover
        self.hasTemplateDefinition = hasTemplateDefinition
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
        hasTemplateDefinition = try container.decodeIfPresent(Bool.self, forKey: .hasTemplateDefinition) ?? false
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
    let reconciled: Bool
    let subtransactions: [ActualTransaction]
    let isParent: Bool
    let isChild: Bool
    let parentID: String?
    let schedule: String?

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
        reconciled: Bool = false,
        subtransactions: [ActualTransaction] = [],
        isParent: Bool = false,
        isChild: Bool = false,
        parentID: String? = nil,
        schedule: String? = nil
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
        self.reconciled = reconciled
        self.subtransactions = subtransactions
        self.isParent = isParent
        self.isChild = isChild
        self.parentID = parentID
        self.schedule = schedule
    }

    enum CodingKeys: String, CodingKey {
        case id, account, date, amount, payee, category, notes, cleared, reconciled, schedule
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
        reconciled = try container.decodeIfPresent(Bool.self, forKey: .reconciled) ?? false
        subtransactions = try container.decodeIfPresent([ActualTransaction].self, forKey: .subtransactions) ?? []
        isParent = try container.decodeIfPresent(Bool.self, forKey: .isParent) ?? !subtransactions.isEmpty
        isChild = try container.decodeIfPresent(Bool.self, forKey: .isChild) ?? false
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
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
