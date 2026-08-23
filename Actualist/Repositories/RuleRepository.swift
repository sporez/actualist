import Foundation

protocol RuleRepositoryProtocol: Sendable {
    @MainActor
    func cachedRules(budgetID: String) -> [ManagedRule]?

    @MainActor
    func refreshRules(budgetID: String) async throws

    @MainActor
    func ruleEditorOptions(budgetID: String) async throws -> RuleEditorOptions

    @MainActor
    func matchingTransactions(
        budgetID: String,
        draft: RuleDraft,
        limit: Int
    ) async throws -> RuleTransactionMatchPreview

    @MainActor
    func createRuleAndRefresh(budgetID: String, draft: RuleDraft) async throws

    @MainActor
    func updateRuleAndRefresh(budgetID: String, ruleID: String, draft: RuleDraft) async throws

    @MainActor
    func deleteRuleAndRefresh(budgetID: String, ruleID: String) async throws
}

struct RuleEditorOptions: Hashable, Sendable {
    let accounts: [RuleEditorChoice]
    let categories: [RuleEditorChoice]
    let categoryGroups: [RuleEditorChoice]
    let payees: [RuleEditorChoice]
}

struct RuleEditorChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isTransfer: Bool

    init(id: String, name: String, isTransfer: Bool = false) {
        self.id = id
        self.name = name
        self.isTransfer = isTransfer
    }
}

struct RuleTransactionMatchPreview: Hashable, Sendable {
    let transactions: [RuleTransactionMatch]
    let totalCount: Int
}

struct RuleTransactionMatch: Identifiable, Hashable, Sendable {
    let id: String
    let date: String
    let payeeName: String
    let categoryName: String
    let accountName: String
    let amountMinorUnits: Int
}

enum RuleStage: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case pre
    case normal
    case post

    var id: String { rawValue }

    var databaseValue: String? {
        self == .normal ? nil : rawValue
    }

    var displayName: String {
        switch self {
        case .pre: "Before other rules"
        case .normal: "Normal"
        case .post: "After other rules"
        }
    }
}

enum RuleConditionJoin: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case and
    case or

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

indirect enum RuleJSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RuleJSONValue])
    case object([String: RuleJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([RuleJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: RuleJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

}

struct RuleCondition: Hashable, Sendable, Codable, Identifiable {
    var id = UUID()
    var field: String
    var operation: String
    var value: RuleJSONValue
    var type: String?
    var options: [String: RuleJSONValue]?

    enum CodingKeys: String, CodingKey {
        case field
        case operation = "op"
        case value, type, options
    }

    init(
        field: String,
        operation: String,
        value: RuleJSONValue,
        type: String? = nil,
        options: [String: RuleJSONValue]? = nil
    ) {
        self.field = field
        self.operation = operation
        self.value = value
        self.type = type
        self.options = options
    }
}

struct RuleAction: Hashable, Sendable, Codable, Identifiable {
    var id = UUID()
    var operation: String
    var field: String?
    var value: RuleJSONValue
    var type: String?
    var options: [String: RuleJSONValue]?

    enum CodingKeys: String, CodingKey {
        case operation = "op"
        case field, value, type, options
    }

    init(
        operation: String,
        field: String? = nil,
        value: RuleJSONValue = .null,
        type: String? = nil,
        options: [String: RuleJSONValue]? = nil
    ) {
        self.operation = operation
        self.field = field
        self.value = value
        self.type = type
        self.options = options
    }
}

struct RuleDraft: Hashable, Sendable {
    var stage: RuleStage
    var conditionsJoin: RuleConditionJoin
    var conditions: [RuleCondition]
    var actions: [RuleAction]

    var canRoundTripAndEvaluate: Bool {
        !conditions.isEmpty
            && !actions.isEmpty
            && conditions.allSatisfy(\.canRoundTripAndEvaluate)
            && actions.allSatisfy(\.canRoundTripAndEvaluate)
    }

    static var blank: RuleDraft {
        RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [RuleCondition(field: "notes", operation: "is", value: .string(""), type: "string")],
            actions: [RuleAction(operation: "set", field: "category", value: .null, type: "id")]
        )
    }

    static func categoryRule(payeeID: String) -> RuleDraft {
        RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [RuleCondition(field: "description", operation: "is", value: .string(payeeID), type: "id")],
            actions: [RuleAction(operation: "set", field: "category", value: .null, type: "id")]
        )
    }
}

extension RuleCondition {
    enum ValueKind: String, Sendable {
        case id
        case string
        case number
        case date
        case boolean
    }

    static let editableFields: [(name: String, value: String)] = [
        ("Imported Payee", "imported_payee"),
        ("Payee Name", "payee_name"),
        ("Account", "account"),
        ("Category", "category"),
        ("Category Group", "category_group"),
        ("Date", "date"),
        ("Payee", "payee"),
        ("Notes", "notes"),
        ("Amount", "amount"),
        ("Amount (Inflow)", "amount-inflow"),
        ("Amount (Outflow)", "amount-outflow"),
        ("Cleared", "cleared"),
        ("Reconciled", "reconciled"),
        ("Transfer", "transfer"),
        ("Parent Transaction", "parent")
    ]

    static func valueKind(for field: String) -> ValueKind? {
        switch serializedField(field) {
        case "account", "category", "category_group", "description": .id
        case "imported_payee", "payee_name", "notes": .string
        case "amount": .number
        case "date": .date
        case "cleared", "reconciled", "transfer", "parent": .boolean
        default: nil
        }
    }

    static func operations(for field: String) -> [String] {
        switch valueKind(for: field) {
        case .id:
            var operations = ["is", "oneOf", "isNot", "notOneOf"]
            if serializedField(field) == "account" {
                operations.append(contentsOf: ["onBudget", "offBudget"])
            }
            return operations
        case .string:
            var operations = ["is", "contains", "matches", "oneOf", "isNot", "doesNotContain", "notOneOf", "hasTags", "hasAnyTag"]
            if serializedField(field) == "imported_payee" {
                operations.removeAll { $0 == "hasTags" || $0 == "hasAnyTag" }
            }
            if serializedField(field) == "notes" {
                operations.removeAll { $0 == "oneOf" || $0 == "notOneOf" }
            }
            return operations
        case .number:
            return isDirectionalAmountField(field)
                ? ["is", "isapprox", "gt", "gte", "lt", "lte"]
                : ["is", "isapprox", "isbetween", "gt", "gte", "lt", "lte"]
        case .date:
            return ["is", "isapprox", "gt", "gte", "lt", "lte"]
        case .boolean:
            return ["is"]
        case nil:
            return []
        }
    }

    static func serializedField(_ field: String) -> String {
        switch field {
        case "amount-inflow", "amount-outflow": "amount"
        case "payee": "description"
        default: field
        }
    }

    static func isDirectionalAmountField(_ field: String) -> Bool {
        field == "amount-inflow" || field == "amount-outflow"
    }

    static func options(for field: String) -> [String: RuleJSONValue]? {
        switch field {
        case "amount-inflow": ["inflow": .bool(true)]
        case "amount-outflow": ["outflow": .bool(true)]
        default: nil
        }
    }

    var editorField: String {
        if field == "description" { return "payee" }
        if field == "amount", options?["inflow"] == .bool(true) { return "amount-inflow" }
        if field == "amount", options?["outflow"] == .bool(true) { return "amount-outflow" }
        return field
    }

    var canRoundTripAndEvaluate: Bool {
        guard Self.operations(for: editorField).contains(operation), hasSupportedOptions else { return false }
        guard type == nil || type == Self.valueKind(for: field)?.rawValue else { return false }
        if operation == "oneOf" || operation == "notOneOf" {
            guard case .array(let values) = value,
                  values.allSatisfy({ if case .string = $0 { true } else { false } }) else { return false }
        } else {
            switch Self.valueKind(for: field) {
            case .number:
                guard operation == "isbetween" || value.isNumberLike else { return false }
            case .date:
                guard case .string(let dateValue) = value,
                      Self.isSupportedDate(dateValue, operation: operation) else { return false }
            case .id:
                guard operation == "onBudget" || operation == "offBudget" || value.isStringLike else { return false }
            case .string:
                guard case .string(let string) = value else { return false }
                if ["contains", "doesNotContain", "matches", "hasTags", "hasAnyTag"].contains(operation),
                   string.isEmpty { return false }
            case .boolean:
                guard case .bool = value else { return false }
            case nil:
                return false
            }
        }
        if operation == "isbetween" {
            guard case .object(let range) = value,
                  range["num1"] != nil,
                  range["num2"] != nil else { return false }
        }
        return true
    }

    private var hasSupportedOptions: Bool {
        guard let options, !options.isEmpty else { return true }
        let allowedKeys: Set<String>
        switch field {
        case "amount": allowedKeys = ["inflow", "outflow"]
        default: return false
        }
        guard Set(options.keys).isSubset(of: allowedKeys),
              options.values.allSatisfy({ if case .bool = $0 { true } else { false } }) else { return false }
        if options["inflow"] == .bool(true), options["outflow"] == .bool(true) { return false }
        return true
    }

    private static func isSupportedDate(_ value: String, operation: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard [1, 2, 3].contains(components.count),
              let year = Int(components[0]), (1...9999).contains(year) else { return false }
        if components.count >= 2 {
            guard components[0].count == 4, components[1].count == 2,
                  let month = Int(components[1]), (1...12).contains(month) else { return false }
        }
        if components.count == 3 {
            guard components[2].count == 2,
                  let date = ruleDateFormatter.date(from: value),
                  ruleDateFormatter.string(from: date) == value else { return false }
        }
        if operation != "is" { return components.count == 3 }
        return value.count == 4 || value.count == 7 || value.count == 10
    }

    private static let ruleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}

extension RuleAction {
    var editorField: String? {
        field == "description" ? "payee" : field
    }

    var canRoundTripAndEvaluate: Bool {
        guard hasSupportedActionOptions else { return false }
        switch operation {
        case "set":
            switch editorField {
            case "account", "category", "date", "notes", "payee": return value.isStringLike
            case "amount": return value.isNumberLike
            case "cleared": if case .bool = value { return true } else { return false }
            default: return false
            }
        case "prepend-notes", "append-notes":
            return field == nil && value.isStringLike && splitIndex == nil
        case "delete-transaction":
            return field == nil && value.isStringLike && splitIndex == nil
        case "set-split-amount":
            return field == nil && value.isNumberLike && splitMethod != nil && splitIndex != nil
        default:
            return false
        }
    }

    var splitIndex: Int? {
        guard let value = options?["splitIndex"] else { return nil }
        switch value {
        case .number(let number):
            guard number.isFinite, number >= 0, number == number.rounded() else { return nil }
            return Int(number)
        case .string(let text):
            return Int(text)
        default:
            return nil
        }
    }

    var splitMethod: String? {
        guard case .string(let method) = options?["method"] else { return nil }
        return method
    }

    private var hasSupportedActionOptions: Bool {
        guard let options, !options.isEmpty else { return true }
        let allowed: Set<String> = ["splitIndex", "method"]
        guard Set(options.keys).isSubset(of: allowed) else { return false }
        if let method = options["method"] {
            guard case .string(let name) = method,
                  ["fixed-amount", "fixed-percent", "remainder"].contains(name) else {
                return false
            }
        }
        if operation == "set-split-amount", options["method"] == nil {
            return false
        }
        if let index = options["splitIndex"] {
            switch index {
            case .number(let number):
                guard number.isFinite, number >= 0, number == number.rounded(), number < 100 else {
                    return false
                }
            case .string(let text):
                guard let value = Int(text), value >= 0, value < 100 else { return false }
            default:
                return false
            }
        }
        return true
    }
}

extension RuleJSONValue {
    var isStringLike: Bool {
        switch self {
        case .string, .null: true
        default: false
        }
    }

    var isNumberLike: Bool {
        switch self {
        case .number: true
        case .string(let value): Double(value) != nil
        default: false
        }
    }
}

struct ManagedRule: Identifiable, Hashable, Sendable {
    let id: String
    let draft: RuleDraft?
    let rawStage: String?
    let rawConditionsJSON: String
    let rawActionsJSON: String
    let payeeIDs: Set<String>
    let isCompletedScheduleRule: Bool
    let rawConditionsJoin: String?

    init(
        id: String,
        draft: RuleDraft?,
        rawStage: String?,
        rawConditionsJSON: String,
        rawActionsJSON: String,
        payeeIDs: Set<String>,
        isCompletedScheduleRule: Bool,
        rawConditionsJoin: String? = nil
    ) {
        self.id = id
        self.draft = draft
        self.rawStage = rawStage
        self.rawConditionsJSON = rawConditionsJSON
        self.rawActionsJSON = rawActionsJSON
        self.payeeIDs = payeeIDs
        self.isCompletedScheduleRule = isCompletedScheduleRule
        self.rawConditionsJoin = rawConditionsJoin
    }

    var isEditable: Bool { draft != nil }
}
