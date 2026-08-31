import Foundation
import Testing
@testable import Actualist

struct RuleSplitActionSafetyTests {
    @Test func splitTargetedActionsAreReadOnlyAndRuntimeDisabled() {
        let actions = [
            RuleAction(
                operation: "set-split-amount",
                value: .number(4_000),
                options: ["method": .string("fixed-amount"), "splitIndex": .number(1)]
            ),
            RuleAction(
                operation: "set",
                field: "category",
                value: .string("groceries"),
                options: ["splitIndex": .number(1)]
            ),
            RuleAction(
                operation: "append-notes",
                value: .string("unsafe"),
                options: ["method": .string("remainder")]
            )
        ]

        for action in actions {
            #expect(action.targetsSplitTransaction)
            #expect(!action.canRoundTripAndEvaluate)
            #expect(!action.canExecuteAtRuntime)
        }
    }

    @Test func ordinaryAndScheduleActionsKeepTheirExistingCapabilities() {
        let ordinary = RuleAction(
            operation: "set",
            field: "category",
            value: .string("groceries")
        )
        let schedule = RuleAction(operation: "link-schedule", value: .string("schedule-1"))

        #expect(!ordinary.targetsSplitTransaction)
        #expect(ordinary.canRoundTripAndEvaluate)
        #expect(ordinary.canExecuteAtRuntime)
        #expect(!schedule.canRoundTripAndEvaluate)
        #expect(schedule.canExecuteAtRuntime)
    }
}

extension LocalFirstActualStoreTests {
    @Test func importedSplitRuleStaysReadOnlyAndDoesNotExecute() async throws {
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
                '[{"op":"set-split-amount","value":4000,"options":{"method":"fixed-amount","splitIndex":1}},{"op":"set","field":"category","value":"groceries","options":{"splitIndex":1}},{"op":"set-split-amount","value":0,"options":{"method":"remainder","splitIndex":2}},{"op":"set","field":"category","value":"utilities","options":{"splitIndex":2}}]',
                'and',
                0
            );
            """)
        let database = try #require(store.database)
        let imported = try #require(try await database.fetchRules().first { $0.id == "split-rule" })

        #expect(!imported.isEditable)
        #expect(imported.rawActionsJSON.contains("set-split-amount"))

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
        #expect(preview.splits.isEmpty)
        #expect(preview.categoryID == nil)

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        #expect(!created.isParent)
        #expect(created.subtransactions.isEmpty)
    }

    @Test func programmaticSplitRuleWritesFailClosed() async throws {
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
                'existing-rule',
                NULL,
                '[{"op":"is","field":"description","value":"coffee"}]',
                '[{"op":"set","field":"category","value":"groceries"}]',
                'and',
                0
            );
            """)
        let draft = RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [
                RuleCondition(field: "description", operation: "is", value: .string("coffee"))
            ],
            actions: [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(4_000),
                    options: ["method": .string("fixed-amount"), "splitIndex": .number(1)]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["method": .string("remainder"), "splitIndex": .number(2)]
                )
            ]
        )

        #expect(!draft.canRoundTripAndEvaluate)
        await #expect(throws: LocalFirstError.self) {
            try await store.createRuleAndRefresh(budgetID: "group-1", draft: draft)
        }
        await #expect(throws: LocalFirstError.self) {
            try await store.updateRuleAndRefresh(
                budgetID: "group-1",
                ruleID: "existing-rule",
                draft: draft
            )
        }
    }
}
