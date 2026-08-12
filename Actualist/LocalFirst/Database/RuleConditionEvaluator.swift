import Foundation

struct RuleEvaluationContext {
    var accountID: String
    var accountName: String
    var accountIsOffBudget: Bool
    var amount: Int
    var categoryID: String?
    var categoryName: String?
    var categoryGroupID: String?
    var categoryGroupName: String?
    var date: Date
    var notes: String?
    var payeeID: String?
    var payeeName: String
    var importedPayee: String?
    var cleared: Bool
    var reconciled: Bool
    var isTransfer: Bool
    var isParent: Bool
    var accountNames: [String: String]
    var offBudgetAccountIDs: Set<String>
    var categoryNames: [String: String]
    var categoryGroupsByCategoryID: [String: String]
    var categoryGroupNames: [String: String]
    var payeeNames: [String: String]
}

enum RuleConditionEvaluator {
    static func applying(_ rules: [ManagedRule], to context: RuleEvaluationContext) -> RuleEvaluationContext {
        var result = context
        for rule in rules where !rule.isCompletedScheduleRule {
            guard let draft = rule.draft else { continue }
            let matches = draft.conditions.map { conditionMatches($0, context: result) }
            let shouldApply = draft.conditionsJoin == .and
                ? matches.allSatisfy { $0 }
                : matches.contains(true)
            guard shouldApply else { continue }
            for action in draft.actions {
                apply(action: action, context: &result)
            }
        }
        return result
    }

    static func conditionMatches(_ condition: RuleCondition, context: RuleEvaluationContext) -> Bool {
        if condition.field == "account" && condition.operation == "onBudget" {
            return !context.accountIsOffBudget
        }
        if condition.field == "account" && condition.operation == "offBudget" {
            return context.accountIsOffBudget
        }

        let kind = RuleCondition.valueKind(for: condition.field)
        var actual: RuleJSONValue
        switch condition.field {
        case "account": actual = .string(context.accountID)
        case "amount": actual = .number(Double(context.amount))
        case "category": actual = context.categoryID.map(RuleJSONValue.string) ?? .null
        case "category_group": actual = context.categoryGroupID.map(RuleJSONValue.string) ?? .null
        case "date": actual = .string(ruleDateFormatter.string(from: context.date))
        case "notes": actual = .string(context.notes ?? "")
        case "payee": actual = context.payeeID.map(RuleJSONValue.string) ?? .null
        case "imported_payee": actual = .string(context.importedPayee ?? "")
        case "payee_name": actual = .string(context.payeeName)
        case "cleared": actual = .bool(context.cleared)
        case "reconciled": actual = .bool(context.reconciled)
        case "transfer": actual = .bool(context.isTransfer)
        case "parent": actual = .bool(context.isParent)
        default: return false
        }

        if condition.field == "amount", let options = condition.options {
            if options["outflow"] == .bool(true) {
                guard context.amount <= 0 else { return false }
                actual = .number(-Double(context.amount))
            } else if options["inflow"] == .bool(true) {
                guard context.amount >= 0 else { return false }
            }
        }

        if ["contains", "doesNotContain", "matches"].contains(condition.operation) {
            switch condition.field {
            case "account": actual = .string(context.accountName)
            case "category":
                guard context.categoryID != nil else { return false }
                actual = .string(context.categoryName ?? "")
            case "category_group":
                guard context.categoryGroupID != nil else { return false }
                actual = .string(context.categoryGroupName ?? "")
            case "payee":
                guard context.payeeID != nil else { return false }
                actual = .string(context.payeeName)
            default: break
            }
        }

        if kind == .date {
            return compareDate(actual: actual, operation: condition.operation, expected: condition.value)
        }
        return compare(actual: actual, operation: condition.operation, expected: condition.value, kind: kind)
    }

    private static func compare(
        actual: RuleJSONValue,
        operation: String,
        expected: RuleJSONValue,
        kind: RuleCondition.ValueKind?
    ) -> Bool {
        switch operation {
        case "is": return equivalent(actual, expected, kind: kind)
        case "isNot": return !equivalent(actual, expected, kind: kind)
        case "oneOf", "notOneOf":
            guard actual != .null, case .array(let values) = expected else { return false }
            let contains = values.contains { equivalent(actual, $0, kind: kind) }
            return operation == "oneOf" ? contains : !contains
        case "contains", "doesNotContain", "matches", "hasTags", "hasAnyTag":
            guard actual != .null else { return false }
            let actualText = actual.editableText.lowercased()
            let expectedText = normalizedExpectedText(expected.editableText, kind: kind)
            let matches: Bool
            if operation == "matches" {
                matches = (try? NSRegularExpression(pattern: expectedText))
                    .map { $0.firstMatch(in: actualText, range: NSRange(actualText.startIndex..., in: actualText)) != nil }
                    ?? false
            } else if operation == "hasTags" || operation == "hasAnyTag" {
                let tags = extractTags(expectedText)
                let tagMatches = tags.map { tag in
                    let pattern = "(?<!#)\(NSRegularExpression.escapedPattern(for: tag))([\\s#]|$)"
                    return actualText.range(of: pattern, options: .regularExpression) != nil
                }
                matches = operation == "hasTags" ? tagMatches.allSatisfy { $0 } : tagMatches.contains(true)
            } else {
                matches = actualText.contains(expectedText)
            }
            return operation == "doesNotContain" ? !matches : matches
        case "gt", "gte", "lt", "lte", "isapprox":
            guard let lhs = numericValue(actual), let rhs = numericValue(expected) else { return false }
            switch operation {
            case "gt": return lhs > rhs
            case "gte": return lhs >= rhs
            case "lt": return lhs < rhs
            case "lte": return lhs <= rhs
            default:
                let threshold = (abs(rhs) * 0.075).rounded()
                return lhs >= rhs - threshold && lhs <= rhs + threshold
            }
        case "isbetween":
            guard case .object(let range) = expected,
                  let lhs = numericValue(actual),
                  let first = range["num1"].flatMap(numericValue),
                  let second = range["num2"].flatMap(numericValue) else { return false }
            return lhs >= min(first, second) && lhs <= max(first, second)
        default: return false
        }
    }

    private static func compareDate(actual: RuleJSONValue, operation: String, expected: RuleJSONValue) -> Bool {
        guard case .string(let actualDate) = actual, case .string(let expectedDate) = expected else { return false }
        switch operation {
        case "is":
            switch expectedDate.count {
            case 4: return actualDate.hasPrefix(expectedDate + "-")
            case 7: return actualDate.hasPrefix(expectedDate + "-")
            case 10: return actualDate == expectedDate
            default: return false
            }
        case "isapprox":
            guard let actualValue = ruleDateFormatter.date(from: actualDate),
                  let expectedValue = ruleDateFormatter.date(from: expectedDate) else { return false }
            return abs(actualValue.timeIntervalSince(expectedValue)) <= 2 * 24 * 60 * 60
        case "gt": return actualDate > expectedDate
        case "gte": return actualDate >= expectedDate
        case "lt": return actualDate < expectedDate
        case "lte": return actualDate <= expectedDate
        default: return false
        }
    }

    private static func equivalent(
        _ lhs: RuleJSONValue,
        _ rhs: RuleJSONValue,
        kind: RuleCondition.ValueKind?
    ) -> Bool {
        if let lhsNumber = numericValue(lhs), let rhsNumber = numericValue(rhs) {
            return lhsNumber == rhsNumber
        }
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.string(let lhs), .string(let rhs)):
            return lhs.lowercased() == normalizedExpectedText(rhs, kind: kind)
        default: return false
        }
    }

    private static func normalizedExpectedText(_ value: String, kind: RuleCondition.ValueKind?) -> String {
        kind == .string ? value.lowercased() : value
    }

    private static func extractTags(_ value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "#*([^#\\s]+)") else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        var seen = Set<String>()
        var tags: [String] = []
        for match in expression.matches(in: value, range: range) {
            guard let tagRange = Range(match.range(at: 1), in: value) else { continue }
            let tag = "#" + value[tagRange]
            if seen.insert(tag).inserted { tags.append(tag) }
        }
        return tags
    }

    private static func numericValue(_ value: RuleJSONValue) -> Double? {
        switch value {
        case .number(let number): number
        case .string(let string): Double(string)
        default: nil
        }
    }

    private static func apply(action: RuleAction, context: inout RuleEvaluationContext) {
        switch action.operation {
        case "set":
            switch action.field {
            case "account":
                if case .string(let value) = action.value {
                    context.accountID = value
                    context.accountName = context.accountNames[value] ?? ""
                    context.accountIsOffBudget = context.offBudgetAccountIDs.contains(value)
                }
            case "amount":
                if let value = numericValue(action.value) { context.amount = Int(value.rounded()) }
            case "category":
                context.categoryID = stringOrNil(action.value)
                context.categoryName = context.categoryID.flatMap { context.categoryNames[$0] }
                context.categoryGroupID = context.categoryID.flatMap { context.categoryGroupsByCategoryID[$0] }
                context.categoryGroupName = context.categoryGroupID.flatMap { context.categoryGroupNames[$0] }
            case "date":
                if case .string(let value) = action.value, let date = ruleDateFormatter.date(from: value) {
                    context.date = date
                }
            case "notes": context.notes = stringOrNil(action.value)
            case "payee":
                context.payeeID = stringOrNil(action.value)
                context.payeeName = context.payeeID.flatMap { context.payeeNames[$0] } ?? ""
            case "cleared":
                if case .bool(let value) = action.value { context.cleared = value }
            default: break
            }
        case "prepend-notes":
            if case .string(let value) = action.value { context.notes = value + (context.notes ?? "") }
        case "append-notes":
            if case .string(let value) = action.value { context.notes = (context.notes ?? "") + value }
        default: break
        }
    }

    private static func stringOrNil(_ value: RuleJSONValue) -> String? {
        if case .string(let string) = value { return string.isEmpty ? nil : string }
        return nil
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
