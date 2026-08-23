import Foundation
import Testing
@testable import Actualist

struct RuleSplitActionTests {
    @Test func fixedAndRemainderSplitsSumToParentAmount() {
        let result = RuleSplitActionExecutor.apply(
            [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(4_000),
                    options: ["method": .string("fixed-amount"), "splitIndex": .number(0)]
                ),
                RuleAction(
                    operation: "set",
                    field: "category",
                    value: .string("groceries"),
                    options: ["splitIndex": .number(0)]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["method": .string("remainder"), "splitIndex": .number(1)]
                ),
                RuleAction(
                    operation: "set",
                    field: "category",
                    value: .string("dining"),
                    options: ["splitIndex": .number(1)]
                )
            ],
            startingAmount: -10_000
        )

        #expect(result.map(\.amount) == [-4_000, -6_000])
        #expect(result.map(\.categoryID) == ["groceries", "dining"])
    }

    @Test func percentAppliesToRemainderAfterFixedAmount() {
        let result = RuleSplitActionExecutor.apply(
            [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(2_000),
                    options: ["method": .string("fixed-amount"), "splitIndex": .number(0)]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(50),
                    options: ["method": .string("fixed-percent"), "splitIndex": .number(1)]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["method": .string("remainder"), "splitIndex": .number(2)]
                )
            ],
            startingAmount: -10_000
        )

        #expect(result.map(\.amount) == [-2_000, -4_000, -4_000])
    }

    @Test func twoRemaindersGiveLeftoverToTheLastSplit() {
        let result = RuleSplitActionExecutor.apply(
            [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["method": .string("remainder"), "splitIndex": .number(0)]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["method": .string("remainder"), "splitIndex": .number(1)]
                )
            ],
            startingAmount: -5
        )

        #expect(result.map(\.amount) == [-2, -3])
    }

    @Test func formulaSplitMethodStaysUneditable() {
        let action = RuleAction(
            operation: "set-split-amount",
            value: .number(0),
            options: ["method": .string("formula"), "splitIndex": .number(0)]
        )
        #expect(!action.canRoundTripAndEvaluate)
    }

    @Test func supportedSplitActionsRoundTrip() {
        let action = RuleAction(
            operation: "set-split-amount",
            value: .number(1_500),
            options: ["method": .string("fixed-amount"), "splitIndex": .number(0)]
        )
        #expect(action.canRoundTripAndEvaluate)
        #expect(action.canExecuteAtRuntime)
    }
}

private extension RuleSplitActionExecutor {
    static func apply(_ actions: [RuleAction], startingAmount: Int) -> [RuleEvaluationSplit] {
        var context = RuleEvaluationContext(
            accountID: "checking",
            accountName: "Checking",
            accountIsOffBudget: false,
            amount: startingAmount,
            categoryID: "groceries",
            categoryName: "Groceries",
            categoryGroupID: nil,
            categoryGroupName: nil,
            date: Date(timeIntervalSince1970: 0),
            notes: nil,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            importedPayee: nil,
            cleared: false,
            reconciled: false,
            isTransfer: false,
            isParent: false,
            accountNames: [:],
            offBudgetAccountIDs: [],
            categoryNames: [:],
            categoryGroupsByCategoryID: [:],
            categoryGroupNames: [:],
            payeeNames: [:]
        )
        apply(actions, to: &context)
        return context.splits
    }
}

extension LocalFirstActualStoreTests {
    @Test func matchingSplitRulePersistsParentAndChildren() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions TEXT,
                actions TEXT,
                conditions_op TEXT DEFAULT 'and',
                tombstone INTEGER DEFAULT 0
            );
            INSERT INTO rules VALUES (
                'split-rule',
                NULL,
                '[{"op":"is","field":"description","value":"coffee"}]',
                '[{"op":"set-split-amount","value":4000,"options":{"method":"fixed-amount","splitIndex":0}},{"op":"set","field":"category","value":"groceries","options":{"splitIndex":0}},{"op":"set-split-amount","value":0,"options":{"method":"remainder","splitIndex":1}},{"op":"set","field":"category","value":"utilities","options":{"splitIndex":1}}]',
                'and',
                0
            );
            """)

        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 8, day: 11),
            amountMinorUnits: -10_000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let preview = try await store.previewRules(for: draft, budgetID: "group-1")
        #expect(preview.splits.map(\.amountMinorUnits) == [-4_000, -6_000])
        #expect(preview.splits.map(\.categoryID) == ["groceries", "utilities"])

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        #expect(created.isParent)
        #expect(created.subtransactions.count == 2)
        #expect(Set(created.subtransactions.compactMap(\.amount)) == [-4_000, -6_000])
        #expect(Set(created.subtransactions.compactMap(\.category)) == ["groceries", "utilities"])
    }
}
