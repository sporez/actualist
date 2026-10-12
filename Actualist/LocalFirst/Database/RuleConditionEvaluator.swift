import Foundation

struct RuleEvaluationSplit: Equatable, Sendable {
    var id: String? = nil
    var categoryID: String?
    var amount: Int
    var payeeID: String? = nil
    var notes: String? = nil
    var sortOrder: Double? = nil
}

struct RuleEvaluationContext {
    var evaluationID = "parent-1"
    var accountID: String
    var accountName: String
    var accountIsOffBudget: Bool
    var amount: Int
    var categoryID: String?
    var categoryName: String?
    var categoryGroupID: String?
    var categoryGroupName: String?
    var date: Date
    var dateTimeZone: TimeZone = .autoupdatingCurrent
    var notes: String?
    var payeeID: String?
    var payeeName: String
    var importedPayee: String?
    var cleared: Bool
    var reconciled: Bool
    var isTransfer: Bool
    var isParent: Bool
    var isChild = false
    var parentID: String? = nil
    var sortOrder: Double? = nil
    var startingBalance = false
    var balance = 0
    var balanceOfPrefetch: [String: Int] = [:]
    var scheduleID: String? = nil
    var deletesTransaction = false
    var splits: [RuleEvaluationSplit] = []
    var accountNames: [String: String]
    var offBudgetAccountIDs: Set<String>
    var categoryNames: [String: String]
    var categoryGroupsByCategoryID: [String: String]
    var categoryGroupNames: [String: String]
    var payeeNames: [String: String]
}

enum RuleConditionEvaluator {
    static func applying(
        _ rules: [ManagedRule],
        to context: RuleEvaluationContext,
        schedules: RuleScheduleIndex = .empty
    ) -> RuleEvaluationContext {
        var result = context
        let candidatePayeeID = context.payeeID
        let candidateImportedPayee = context.importedPayee
        let attachedRuleID = schedules.ruleID(forScheduleID: context.scheduleID)
        for rule in rules {
            if schedules.shouldSkip(ruleID: rule.id, attachedRuleID: attachedRuleID) {
                continue
            }
            let forceExecute = schedules.shouldForceExecute(
                ruleID: rule.id,
                attachedRuleID: attachedRuleID
            )
            guard let execution = rule.executionDraft(),
                  execution.actions.allSatisfy(\.canExecuteAtRuntime) else {
                continue
            }
            guard RuleCandidateIndex.isCandidate(
                execution, payeeID: candidatePayeeID, importedPayee: candidateImportedPayee
            ) else { continue }
            if !forceExecute {
                guard conditionsMatch(execution, context: result, readsTransferAndParent: false) else { continue }
            }
            // Actual only marks the transaction deleted; later rules and this rule's other actions still run.
            let actions = execution.actions.filter { $0.operation != "delete-transaction" }
            if actions.count != execution.actions.count { result.deletesTransaction = true }
            if actions.contains(where: { ($0.splitIndex ?? 0) != 0 || $0.operation == "set-split-amount" }) {
                guard RuleSplitActionExecutor.apply(actions: actions, context: &result) else {
                    continue
                }
            } else {
                for action in actions {
                    apply(action: action, context: &result)
                }
            }
        }
        return result
    }

    /// `readsTransferAndParent` is false while rules run on a transaction: Actual's `runRules` never
    /// fills `transfer` or `parent`, so conditions on them cannot match. Matching saved transactions
    /// (the editor's preview) reads the real values.
    static func conditionsMatch(
        _ draft: RuleDraft,
        context: RuleEvaluationContext,
        readsTransferAndParent: Bool = true
    ) -> Bool {
        guard !draft.conditions.isEmpty else { return false }
        let matches = draft.conditions.map {
            conditionMatches($0, context: context, readsTransferAndParent: readsTransferAndParent)
        }
        return draft.conditionsJoin == .and
            ? matches.allSatisfy { $0 }
            : matches.contains(true)
    }

    static func conditionMatches(
        _ condition: RuleCondition,
        context: RuleEvaluationContext,
        readsTransferAndParent: Bool = true
    ) -> Bool {
        let field = RulePresentation.presentationField(condition.field)
        if !readsTransferAndParent, field == "transfer" || field == "parent" { return false }
        if field == "account" && condition.operation == "onBudget" {
            return !context.accountIsOffBudget
        }
        if field == "account" && condition.operation == "offBudget" {
            return context.accountIsOffBudget
        }

        let kind = RuleCondition.valueKind(for: field)
        var actual: RuleJSONValue
        switch field {
        case "account": actual = .string(context.accountID)
        case "amount": actual = .number(Double(context.amount))
        case "category": actual = context.categoryID.map(RuleJSONValue.string) ?? .null
        case "category_group": actual = context.categoryGroupID.map(RuleJSONValue.string) ?? .null
        case "date": actual = .string(ActualDateOnly.dayID(from: context.date, timeZone: context.dateTimeZone))
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

        if field == "amount", let options = condition.options {
            if options["outflow"] == .bool(true) {
                guard context.amount <= 0 else { return false }
                actual = .number(-Double(context.amount))
            } else if options["inflow"] == .bool(true) {
                guard context.amount >= 0 else { return false }
            }
        }

        if ["contains", "doesNotContain", "matches"].contains(condition.operation) {
            switch field {
            case "account": actual = .string(context.accountName)
            case "category":
                guard context.categoryID != nil else { return false }
                actual = .string(context.categoryName ?? "")
            case "category_group":
                guard context.categoryGroupID != nil else { return false }
                actual = .string(context.categoryGroupName ?? "")
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
            let actualText = comparisonText(actual).lowercased()
            let expectedText = normalizedExpectedText(comparisonText(expected), kind: kind)
            let matches: Bool
            if operation == "matches" {
                matches = RuleRegexCache.expression(for: expectedText)
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

    private static func comparisonText(_ value: RuleJSONValue) -> String {
        switch value {
        case .null:
            return ""
        case .bool(let enabled):
            return enabled ? "true" : "false"
        case .number(let number):
            guard number.isFinite else { return "" }
            if number.rounded() == number,
               number >= Double(Int.min),
               number <= Double(Int.max) {
                return String(Int(number))
            }
            return String(number)
        case .string(let text):
            return text
        case .array(let values):
            return values.map(comparisonText).joined(separator: ", ")
        case .object:
            return ""
        }
    }

    private static func compareDate(actual: RuleJSONValue, operation: String, expected: RuleJSONValue) -> Bool {
        if case .string(let actualDate) = actual, case .object = expected {
            return RuleRecurrenceDateMatcher.matches(dayID: actualDate, operation: operation, recurrence: expected)
        }
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
            guard let distance = ActualDateOnly.dayDistance(from: actualDate, to: expectedDate) else { return false }
            return abs(distance) <= 2
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
            return kind == .string
                ? lhs.lowercased() == rhs.lowercased()
                : lhs == rhs
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

    static func apply(action: RuleAction, context: inout RuleEvaluationContext) {
        switch action.operation {
        case "set":
            switch action.editorField {
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
                if case .string(let value) = action.value,
                   let date = ActualDateOnly.date(from: value, timeZone: context.dateTimeZone) {
                    context.date = date
                }
            case "notes":
                // Unlike the other text fields, an empty note is stored as an empty note.
                if case .string(let notes) = action.value { context.notes = notes } else { context.notes = nil }
            case "payee":
                // payee_name stays what it was before any rule ran, as in Actual.
                context.payeeID = stringOrNil(action.value)
            case "cleared":
                if case .bool(let value) = action.value { context.cleared = value }
            default: break
            }
        case "prepend-notes":
            if case .string(let value) = action.value { context.notes = value + (context.notes ?? "") }
        case "append-notes":
            if case .string(let value) = action.value { context.notes = (context.notes ?? "") + value }
        case "link-schedule":
            if case .string(let value) = action.value, !value.isEmpty {
                context.scheduleID = value
            }
        default: break
        }
    }

    private static func stringOrNil(_ value: RuleJSONValue) -> String? {
        if case .string(let string) = value { return string.isEmpty ? nil : string }
        return nil
    }
}
