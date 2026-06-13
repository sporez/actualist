import Foundation

struct APIDataResponse<Value: Decodable>: Decodable {
    let data: Value
}

struct ActualBudget: Decodable, Identifiable, Hashable {
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

struct ActualAccount: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let offbudget: Bool
    let closed: Bool
}

struct AccountDisplay: Identifiable, Hashable {
    let account: ActualAccount
    let balance: Int?

    var id: String { account.id }
}

struct BudgetMonth: Decodable, Hashable {
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

struct BudgetMonthCategoryGroup: Decodable, Identifiable, Hashable {
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

struct BudgetMonthCategory: Decodable, Identifiable, Hashable {
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

struct ActualPayee: Decodable, Identifiable, Hashable {
    let id: String?
    let name: String
    let category: String?
    let transferAccount: String?

    enum CodingKeys: String, CodingKey {
        case id, name, category
        case transferAccount = "transfer_acct"
    }
}

struct ActualCategory: Decodable, Identifiable, Hashable {
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

struct ActualTransaction: Decodable, Identifiable, Hashable {
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

    enum CodingKeys: String, CodingKey {
        case id, account, date, amount, payee, category, notes, cleared
        case payeeName = "payee_name"
        case importedPayee = "imported_payee"
    }
}

enum FlexibleBool: Decodable, Hashable {
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

    var boolValue: Bool {
        switch self {
        case .bool(let value): value
        case .string(let value): ["true", "cleared", "1"].contains(value.lowercased())
        }
    }
}
