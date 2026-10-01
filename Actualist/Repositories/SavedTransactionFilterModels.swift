import Foundation

enum SavedTransactionFilterCompatibility: Hashable, Sendable {
    case supported
    case unsupported(String)
}

struct SavedTransactionFilter: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let rawName: String?
    let conditionsOperation: String?
    let rawConditionsJSON: String?
    let conditions: [RuleCondition]?
    let queryJoin: TransactionQueryJoin?
    let queryConditions: [TransactionQueryCondition]?
    let tombstone: Bool
    let compatibility: SavedTransactionFilterCompatibility

    var isSupported: Bool { compatibility == .supported }
}

enum SavedTransactionFilterReadResult: Sendable {
    case available([SavedTransactionFilter])
    case unavailable(String)
}

enum SavedTransactionFilterMutationError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidName
    case duplicateName(String)
    case missingConditions
    case duplicateConditions(String)
    case missingFilter
    case unsupportedFilter

    var errorDescription: String? {
        switch self {
        case .unavailable: "Saved filters cannot be changed in this budget."
        case .invalidName: "Enter a name for this saved filter."
        case .duplicateName(let name): "There is already a saved filter named \(name)."
        case .missingConditions: "Choose at least one condition for this saved filter."
        case .duplicateConditions(let name): "These conditions are already saved as \(name)."
        case .missingFilter: "This saved filter is no longer available."
        case .unsupportedFilter: "This saved filter contains conditions that cannot be edited here."
        }
    }
}

struct SavedTransactionFilterDraft: Sendable {
    let name: String
    let conditions: [RuleCondition]
    let join: RuleConditionJoin
}

struct SavedTransactionFilterUpdate: Sendable {
    let filterID: String
    let name: String
    /// `nil` changes only the name and preserves the exact stored condition bytes.
    let conditions: [RuleCondition]?
    let join: RuleConditionJoin?
}

struct SavedTransactionFilterMutationContext: Hashable, Sendable {
    let budgetID: String
    let generation: Int
}

struct SavedTransactionFilterMutationResult: Sendable {
    let filters: [SavedTransactionFilter]?
    let changed: Bool
    let appliedMessageCount: Int
    let refreshPending: Bool
    let sessionCurrent: Bool
}

struct SavedTransactionFilterCommitReceipt: Sendable {
    let changed: Bool
    let appliedMessageCount: Int
}

extension RuleCondition {
    init?(savedQueryCondition condition: TransactionQueryCondition) {
        switch condition {
        case .date(let date):
            self.init(field: "date", operation: date.operation.rawValue, value: .string(date.day.rawValue), type: "date")
        case .account(let id):
            self.init(savedIDCondition: id, field: "account")
        case .payee(let id):
            self.init(savedIDCondition: id, field: "description")
        case .category(let id):
            self.init(savedIDCondition: id, field: "category")
        case .transfer:
            return nil
        }
    }

    private init?(savedIDCondition condition: TransactionQueryIDCondition, field: String) {
        let value: RuleJSONValue
        switch condition.operation {
        case .isEqual, .isNotEqual:
            guard condition.values.count == 1 else { return nil }
            value = condition.values[0].map(RuleJSONValue.string) ?? .null
        case .isOneOf, .isNotOneOf:
            value = .array(condition.values.map { $0.map(RuleJSONValue.string) ?? .null })
        }
        self.init(field: field, operation: condition.operation.rawValue, value: value, type: "id")
    }
}

enum SavedTransactionFilterComparator {
    static func duplicateName(
        candidate: String,
        excludingID: String?,
        among filters: [SavedTransactionFilter]
    ) -> SavedTransactionFilter? {
        filters.first {
            !$0.tombstone && $0.id != excludingID && $0.name == candidate
        }
    }

    static func duplicateConditions(
        candidate: [RuleCondition],
        join: RuleConditionJoin,
        excludingID: String? = nil,
        among filters: [SavedTransactionFilter]
    ) -> SavedTransactionFilter? {
        filters.first { filter in
            filter.id != excludingID && hasDuplicateConditions(
                candidate: candidate,
                join: join,
                among: [filter]
            )
        }
    }

    static func hasDuplicateConditions(
        candidate: [RuleCondition],
        join: RuleConditionJoin,
        among filters: [SavedTransactionFilter]
    ) -> Bool {
        guard !candidate.isEmpty else { return false }
        return filters.contains { filter in
            guard !filter.tombstone,
                  let existing = filter.conditions,
                  existing.count == candidate.count,
                  candidate.count == 1 || (filter.conditionsOperation ?? "and") == join.rawValue else {
                return false
            }
            return candidate.allSatisfy { condition in
                existing.contains { conditionsMatch(condition, $0) }
            }
        }
    }

    private static func conditionsMatch(_ lhs: RuleCondition, _ rhs: RuleCondition) -> Bool {
        lhs.field == rhs.field
            && lhs.operation == rhs.operation
            && strictJSONValueEqual(lhs.value, rhs.value)
            && shallowOptionsMatch(lhs.options, rhs.options)
    }

    private static func shallowOptionsMatch(
        _ lhs: [String: RuleJSONValue]?,
        _ rhs: [String: RuleJSONValue]?
    ) -> Bool {
        let left = lhs ?? [:]
        let right = rhs ?? [:]
        guard left.count == right.count else { return false }
        return left.allSatisfy { key, value in
            guard let other = right[key] else { return false }
            return strictJSONValueEqual(value, other)
        }
    }

    private static func strictJSONValueEqual(_ lhs: RuleJSONValue, _ rhs: RuleJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(left), .bool(right)): left == right
        case let (.number(left), .number(right)): left == right
        case let (.string(left), .string(right)): left == right
        // Actual compares object and array operands by JS reference identity.
        // Distinct persisted JSON decodes cannot establish shared identity.
        case (.array, _), (.object, _): false
        default: false
        }
    }
}

extension SavedTransactionFilter {
    static func project(
        id: String,
        name: String?,
        rawConditionsJSON: String?,
        conditionsOperation: String?,
        tombstone: Bool
    ) -> Self {
        let effectiveOperation = conditionsOperation ?? "and"
        let join = RuleConditionJoin(rawValue: effectiveOperation)
        let decoded: [RuleCondition]? = rawConditionsJSON.flatMap { raw in
            guard let data = raw.data(using: .utf8),
                  let values = try? JSONDecoder().decode([RuleCondition].self, from: data),
                  !values.isEmpty else { return nil }
            return values
        }
        let hasKnownKeys = rawConditionsJSON.map(rawConditionsHaveOnlyKnownKeys) ?? false
        let projected = decoded.flatMap { values -> [TransactionQueryCondition]? in
            guard hasKnownKeys else { return nil }
            let conditions = values.compactMap(TransactionQueryCondition.init(savedRuleCondition:))
            guard conditions.count == values.count else { return nil }
            return conditions
        }

        let compatibility: SavedTransactionFilterCompatibility
        if join == nil {
            compatibility = .unsupported("Unknown condition join")
        } else if decoded == nil {
            compatibility = .unsupported("Malformed, empty, or unknown condition data")
        } else if !hasKnownKeys {
            compatibility = .unsupported("Condition contains unknown fields")
        } else if projected == nil {
            compatibility = .unsupported("Condition is not supported by transaction filters")
        } else {
            compatibility = .supported
        }

        return Self(
            id: id,
            name: name ?? "",
            rawName: name,
            conditionsOperation: conditionsOperation,
            rawConditionsJSON: rawConditionsJSON,
            conditions: decoded,
            queryJoin: compatibility == .supported ? TransactionQueryJoin(rawValue: effectiveOperation) : nil,
            queryConditions: compatibility == .supported ? projected : nil,
            tombstone: tombstone,
            compatibility: compatibility
        )
    }

    private static func rawConditionsHaveOnlyKnownKeys(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        let known: Set<String> = ["field", "op", "value", "type", "options"]
        return values.allSatisfy { Set($0.keys).isSubset(of: known) }
    }
}

private extension TransactionQueryCondition {
    init?(savedRuleCondition condition: RuleCondition) {
        let field = RuleCondition.serializedField(condition.field)
        if field == "date" {
            guard let operation = TransactionQueryDateOperation(rawValue: condition.operation),
                  case .string(let value) = condition.value,
                  let day = TransactionQueryDay(rawValue: value),
                  condition.options == nil || condition.options?.isEmpty == true else { return nil }
            self = .date(TransactionQueryDateCondition(operation: operation, day: day))
            return
        }

        guard ["account", "description", "category"].contains(field) else { return nil }
        guard let operation = TransactionQueryIDOperation(rawValue: condition.operation),
              condition.options == nil || condition.options?.isEmpty == true else { return nil }

        let values: [String?]
        switch (operation, condition.value) {
        case (.isEqual, .string(let value)), (.isNotEqual, .string(let value)):
            values = [value]
        case (.isEqual, .null), (.isNotEqual, .null):
            values = [nil]
        case (.isOneOf, .array(let entries)), (.isNotOneOf, .array(let entries)):
            var decoded: [String?] = []
            for entry in entries {
                switch entry {
                case .string(let value): decoded.append(value)
                case .null: decoded.append(nil)
                default: return nil
                }
            }
            values = decoded
        default:
            return nil
        }

        let value: TransactionQueryIDCondition
        switch operation {
        case .isEqual:
            guard values.count == 1 else { return nil }
            value = .equals(values[0])
        case .isNotEqual:
            guard values.count == 1 else { return nil }
            value = .doesNotEqual(values[0])
        case .isOneOf:
            value = .oneOf(values)
        case .isNotOneOf:
            value = .notOneOf(values)
        }
        switch field {
        case "account": self = .account(value)
        case "description": self = .payee(value)
        case "category": self = .category(value)
        default: return nil
        }
    }
}
