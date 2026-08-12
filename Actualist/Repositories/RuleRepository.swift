import Foundation

protocol RuleRepositoryProtocol: Sendable {
    @MainActor
    func cachedRules(budgetID: String) -> [ManagedRule]?

    @MainActor
    func refreshRules(budgetID: String) async throws

    @MainActor
    func createRuleAndRefresh(budgetID: String, draft: RuleDraft) async throws

    @MainActor
    func updateRuleAndRefresh(budgetID: String, ruleID: String, draft: RuleDraft) async throws

    @MainActor
    func deleteRuleAndRefresh(budgetID: String, ruleID: String) async throws
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

    var editableText: String {
        switch self {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .string(let value): value
        case .array(let values): values.map(\.editableText).joined(separator: ", ")
        case .object: ""
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

    static func categoryRule(payeeID: String) -> RuleDraft {
        RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [RuleCondition(field: "payee", operation: "is", value: .string(payeeID), type: "id")],
            actions: [RuleAction(operation: "set", field: "category", value: .null, type: "id")]
        )
    }
}

private extension RuleCondition {
    var canRoundTripAndEvaluate: Bool {
        guard options?.isEmpty != false else { return false }
        let operations: Set<String>
        switch field {
        case "account":
            operations = ["is", "isNot", "oneOf", "notOneOf", "contains", "doesNotContain", "matches", "onBudget", "offBudget"]
        case "category", "category_group", "payee":
            operations = ["is", "isNot", "oneOf", "notOneOf", "contains", "doesNotContain", "matches"]
        case "amount":
            operations = ["is", "isapprox", "isbetween", "gt", "gte", "lt", "lte"]
        case "date":
            operations = ["is", "isapprox", "gt", "gte", "lt", "lte"]
        case "notes":
            operations = ["is", "isNot", "contains", "doesNotContain", "matches", "hasTags", "hasAnyTag"]
        case "cleared", "transfer":
            operations = ["is"]
        default:
            return false
        }
        guard operations.contains(operation) else { return false }
        if operation == "oneOf" || operation == "notOneOf" {
            guard case .array = value else { return false }
        } else {
            switch field {
            case "amount":
                guard operation == "isbetween" || value.isNumberLike else { return false }
            case "date", "account", "category", "category_group", "payee", "notes":
                guard operation == "onBudget" || operation == "offBudget" || value.isStringLike else { return false }
            case "cleared", "transfer":
                guard case .bool = value else { return false }
            default:
                break
            }
        }
        if operation == "isbetween" {
            guard case .object(let range) = value,
                  range["num1"] != nil,
                  range["num2"] != nil else { return false }
        }
        return true
    }
}

private extension RuleAction {
    var canRoundTripAndEvaluate: Bool {
        guard options?.isEmpty != false else { return false }
        switch operation {
        case "set":
            switch field {
            case "account", "category", "date", "notes", "payee": return value.isStringLike
            case "amount": return value.isNumberLike
            case "cleared": if case .bool = value { return true } else { return false }
            default: return false
            }
        case "prepend-notes", "append-notes":
            return field == nil && value.isStringLike
        default:
            return false
        }
    }
}

private extension RuleJSONValue {
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

    var isEditable: Bool { draft != nil }

    var summary: String {
        guard let draft else { return "Unsupported rule" }
        let conditions = draft.conditions.map { "\($0.field) \($0.operation) \($0.value.editableText)" }
            .joined(separator: " \(draft.conditionsJoin.displayName) ")
        let actions = draft.actions.map { action in
            [action.operation, action.field, action.value.editableText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }.joined(separator: ", ")
        return "If \(conditions), then \(actions)"
    }
}
