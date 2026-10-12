import Foundation

/// Which rules Actual's `runRules` considers at all. Actual indexes each rule under its first `payee`
/// condition and its first `imported_payee` condition, then runs only the union of the rules the
/// transaction's payee id and imported-payee first character select, plus the unindexed ones. A rule
/// indexed on both fields that the transaction selects on neither is never evaluated, which is
/// observable: an `or` rule of two `isNot` conditions is skipped.
enum RuleCandidateIndex {
    /// Candidate keys come from the input transaction, before any rule has changed it.
    static func isCandidate(_ draft: RuleDraft, payeeID: String?, importedPayee: String?) -> Bool {
        applicable(draft, field: "payee", transactionKey: key(payeeID, firstCharacterOnly: false))
            || applicable(draft, field: "imported_payee", transactionKey: key(importedPayee, firstCharacterOnly: true))
    }

    private static func applicable(_ draft: RuleDraft, field: String, transactionKey: String?) -> Bool {
        let keys = indexKeys(draft, field: field)
        return keys.contains("*") || transactionKey.map(keys.contains) == true
    }

    /// Keys the rule is listed under; empty when it is listed nowhere (a `oneOf` with no values).
    private static func indexKeys(_ draft: RuleDraft, field: String) -> Set<String> {
        let firstCharacterOnly = field == "imported_payee"
        guard let condition = draft.conditions.first(where: {
            RulePresentation.presentationField($0.field) == field
        }), ["is", "isNot", "oneOf", "notOneOf"].contains(condition.operation) else {
            return ["*"]
        }
        func ruleKey(_ value: RuleJSONValue) -> String {
            if case .string(let text) = value {
                return key(text, firstCharacterOnly: firstCharacterOnly) ?? "*"
            }
            return "*"
        }
        if condition.operation == "oneOf" || condition.operation == "notOneOf" {
            guard case .array(let values) = condition.value else { return [] }
            return Set(values.map(ruleKey))
        }
        return [ruleKey(condition.value)]
    }

    private static func key(_ value: String?, firstCharacterOnly: Bool) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return firstCharacterOnly ? String(value.prefix(1)).lowercased() : value.lowercased()
    }
}
