import Foundation
import Testing
@testable import Actualist

struct RuleDeleteActionTests {
    @Test func deleteTransactionActionRoundTripsAndIsEditable() {
        let action = RuleAction(operation: "delete-transaction", value: .string(""))
        #expect(action.canRoundTripAndEvaluate)
        #expect(action.canExecuteAtRuntime)
        #expect(RulePresentation.actionName("delete-transaction") == "Delete transaction")

        let draft = RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [RuleCondition(field: "description", operation: "is", value: .string("coffee"))],
            actions: [action]
        )
        #expect(draft.canRoundTripAndEvaluate)
    }

    @Test func deleteActionPreventsSiblingActionsAndLaterRules() {
        let deleteRule = ManagedRule(
            id: "delete",
            draft: RuleDraft(
                stage: .normal,
                conditionsJoin: .and,
                conditions: [RuleCondition(field: "description", operation: "is", value: .string("coffee"))],
                actions: [
                    RuleAction(operation: "set", field: "category", value: .string("groceries"), type: "id"),
                    RuleAction(operation: "delete-transaction", value: .string(""))
                ]
            ),
            rawStage: nil,
            rawConditionsJSON: "[]",
            rawActionsJSON: "[]",
            payeeIDs: ["coffee"],
            isCompletedScheduleRule: false
        )
        let laterRule = ManagedRule(
            id: "later",
            draft: RuleDraft(
                stage: .normal,
                conditionsJoin: .and,
                conditions: [RuleCondition(field: "description", operation: "is", value: .string("coffee"))],
                actions: [RuleAction(operation: "set", field: "notes", value: .string("after"), type: "id")]
            ),
            rawStage: nil,
            rawConditionsJSON: "[]",
            rawActionsJSON: "[]",
            payeeIDs: ["coffee"],
            isCompletedScheduleRule: false
        )

        let result = RuleConditionEvaluator.applying(
            [deleteRule, laterRule],
            to: RuleEvaluationContext(
                accountID: "checking",
                accountName: "Checking",
                accountIsOffBudget: false,
                amount: -500,
                categoryID: nil,
                categoryName: nil,
                categoryGroupID: nil,
                categoryGroupName: nil,
                date: Date(timeIntervalSince1970: 0),
                notes: "start",
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                importedPayee: nil,
                cleared: false,
                reconciled: false,
                isTransfer: false,
                isParent: false,
                accountNames: [:],
                offBudgetAccountIDs: [],
                categoryNames: ["groceries": "Groceries"],
                categoryGroupsByCategoryID: [:],
                categoryGroupNames: [:],
                payeeNames: ["coffee": "Coffee Shop"]
            )
        )

        #expect(result.deletesTransaction)
        #expect(result.categoryID == nil)
        #expect(result.notes == "start")
    }

    @Test @MainActor func reviewBlocksSaveUntilPreviewClears() {
        let review = TransactionRuleDeleteReview()
        #expect(!review.blocksSave)
        review.consider(TransactionRulePreview(categoryID: nil, notes: nil, deletesTransaction: true))
        #expect(review.blocksSave)
        #expect(review.isReviewPresented)
        review.dismissReview()
        #expect(review.blocksSave)
        #expect(!review.isReviewPresented)
        review.consider(TransactionRulePreview(categoryID: nil, notes: nil, deletesTransaction: false))
        #expect(!review.blocksSave)
    }

    @Test @MainActor func createAcknowledgesDeleteWithoutTombstoning() async {
        let review = TransactionRuleDeleteReview()
        review.consider(TransactionRulePreview(categoryID: nil, notes: nil, deletesTransaction: true))
        let message = await review.confirmDeletion(
            transactionID: nil,
            accountID: nil,
            date: Date(),
            budgetID: "group-1",
            repository: RecordingTransactionRepository(),
            didDelete: {}
        )
        #expect(message == nil)
        #expect(!review.blocksSave)
    }
}

extension LocalFirstActualStoreTests {
    @Test func deleteTransactionRuleCanBeCreatedAndBlocksMatchingWrites() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions TEXT,
                actions TEXT,
                conditions_op TEXT DEFAULT 'and',
                tombstone INTEGER DEFAULT 0
            );
            """)

        try await store.createRuleAndRefresh(
            budgetID: "group-1",
            draft: RuleDraft(
                stage: .normal,
                conditionsJoin: .and,
                conditions: [RuleCondition(field: "description", operation: "is", value: .string("coffee"), type: "id")],
                actions: [RuleAction(operation: "delete-transaction", value: .string(""))]
            )
        )
        let rule = try #require(store.cachedRules(budgetID: "group-1")?.first)
        #expect(rule.isEditable)

        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 8, day: 11),
            amountMinorUnits: -500,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let preview = try await store.previewRules(for: draft, budgetID: "group-1")
        #expect(preview.deletesTransaction)

        await #expect(throws: LocalFirstError.self) {
            _ = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        }
    }

    @Test func walletImportSkipsCandidatesMatchingADeleteRule() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            ALTER TABLE transactions ADD COLUMN financial_id TEXT;
            ALTER TABLE transactions ADD COLUMN imported_description TEXT;
            ALTER TABLE transactions ADD COLUMN sort_order REAL;
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'delete-cafe',
                '[{"field":"payee_name","op":"is","value":"Delete Cafe"}]',
                '[{"op":"delete-transaction","value":""}]',
                0
            );
            """)
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                    amount: Decimal(string: "3.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Delete Cafe",
                    transactionDescription: "Delete Cafe",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 21),
                    status: .booked
                )
            )
        )

        let result = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        #expect(result.importedCount == 0)
        #expect(result.duplicateCount == 0)
    }
}
