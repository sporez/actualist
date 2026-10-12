import Foundation
import Testing
@testable import Actualist

/// Focused regressions for Actual-compatible rule behavior that the oracle replay reaches only through
/// production drafts: decoding, field spelling, editor choices and the preview's cleared payee.
struct RuleEngineParityTests {
    @Test func deleteTransactionActionDecodesWithoutValueKey() throws {
        let json = #"[{"op":"delete-transaction"},{"op":"set","field":"acct","value":"checking"}]"#
        let actions = try JSONDecoder().decode([RuleAction].self, from: Data(json.utf8))
        #expect(actions.count == 2)
        #expect(actions[0].operation == "delete-transaction")
        #expect(actions[0].value == .null)
        #expect(actions[0].canRoundTripAndEvaluate)
    }

    @Test func accountActionAcceptsActualAndLegacySpellings() {
        let acct = RuleAction(operation: "set", field: "acct", value: .string("checking"))
        let legacy = RuleAction(operation: "set", field: "account", value: .string("checking"))
        #expect(acct.editorField == "account")
        #expect(legacy.editorField == "account")
        #expect(acct.canRoundTripAndEvaluate)
        #expect(legacy.canRoundTripAndEvaluate)
    }

    @Test func editorWritesAccountAsActualStoresIt() {
        #expect(RuleCondition.serializedField("account") == "acct")
        #expect(RuleCondition.serializedField("payee") == "description")
        let stored = RuleCondition(field: "acct", operation: "is", value: .string("checking"), type: "id")
        #expect(stored.editorField == "account")
        #expect(stored.canRoundTripAndEvaluate)
        #expect(RuleCondition.operations(for: "acct").contains("onBudget"))
    }

    @Test func transferAndParentAreNotChoosableButStayVisibleOnExistingRules() {
        let offered = RuleCondition.fieldChoices(including: "notes").map(\.value)
        #expect(!offered.contains("transfer"))
        #expect(!offered.contains("parent"))
        #expect(RuleCondition.fieldChoices(including: "transfer").map(\.value).contains("transfer"))
        #expect(RulePresentation.fieldName("parent") == "Parent Transaction")
    }

    @Test func clearedPayeeProjectsOntoTheDraft() {
        let draft = TransactionDraft(
            accountID: "checking", date: Date(timeIntervalSince1970: 0), amountMinorUnits: -100,
            payeeID: "market", payeeName: "Market", categoryID: nil, notes: nil, cleared: false,
            isTransfer: false
        )
        let unchanged = TransactionRulePreviewProjection.applying(
            TransactionRulePreview(categoryID: nil, notes: nil), to: draft
        )
        let cleared = TransactionRulePreviewProjection.applying(
            TransactionRulePreview(categoryID: nil, notes: nil, clearsPayee: true), to: draft
        )
        #expect(unchanged.payeeID == "market")
        #expect(cleared.payeeID == nil)
    }

    private func draft(_ field: String, _ operation: String, _ value: RuleJSONValue, join: RuleConditionJoin = .and) -> RuleDraft {
        RuleDraft(
            stage: .normal,
            conditionsJoin: join,
            conditions: [RuleCondition(field: field, operation: operation, value: value)],
            actions: [RuleAction(operation: "set", field: "notes", value: .string("x"))]
        )
    }

    @Test func candidateIndexSkipsRulesIndexedOnBothFieldsThatTheTransactionMissesOnBoth() {
        let both = RuleDraft(
            stage: .normal,
            conditionsJoin: .or,
            conditions: [
                RuleCondition(field: "payee", operation: "isNot", value: .string("a")),
                RuleCondition(field: "imported_payee", operation: "isNot", value: .string("zeta"))
            ],
            actions: []
        )
        #expect(!RuleCandidateIndex.isCandidate(both, payeeID: "b", importedPayee: "Other"))
        #expect(RuleCandidateIndex.isCandidate(both, payeeID: "A", importedPayee: "Other"))
        #expect(RuleCandidateIndex.isCandidate(both, payeeID: "b", importedPayee: "Zebra"))
        // Indexed on one field only: the other field's wildcard list always includes it.
        #expect(RuleCandidateIndex.isCandidate(draft("payee", "is", .string("a")), payeeID: "b", importedPayee: nil))
        #expect(RuleCandidateIndex.isCandidate(draft("notes", "is", .string("n")), payeeID: nil, importedPayee: nil))
    }
}
