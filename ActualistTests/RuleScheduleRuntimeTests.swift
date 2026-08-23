import Foundation
import Testing
@testable import Actualist

struct RuleScheduleRuntimeTests {
    private let scheduleA = "sched-a"
    private let scheduleB = "sched-b"
    private let ruleA = "rule-a"
    private let ruleB = "rule-b"

    @Test func matchingUnscheduledDraftAttachesScheduleAndDoesNotRequireEditableDraft() {
        let rule = scheduleOwnedRule(
            id: ruleA,
            scheduleID: scheduleA,
            date: "2026-08-11",
            extraActions: [RuleAction(operation: "set", field: "category", value: .string("groceries"), type: "id")]
        )
        #expect(rule.draft == nil)
        #expect(!rule.isEditable)
        #expect(rule.executionDraft() != nil)
        #expect(RuleAction(operation: "link-schedule", value: .string(scheduleA)).canExecuteAtRuntime)
        #expect(!RuleAction(operation: "link-schedule", value: .string(scheduleA)).canRoundTripAndEvaluate)

        let result = RuleConditionEvaluator.applying(
            [rule],
            to: makeContext(date: date("2026-08-11")),
            schedules: index(active: [scheduleA: ruleA])
        )

        #expect(result.scheduleID == scheduleA)
        #expect(result.categoryID == "groceries")
    }

    @Test func attachedScheduleForceAppliesEvenWhenDateConditionMisses() {
        let rule = scheduleOwnedRule(id: ruleA, scheduleID: scheduleA, date: "2026-08-11")
        var context = makeContext(date: date("2026-01-01"))
        context.scheduleID = scheduleA

        let result = RuleConditionEvaluator.applying(
            [rule],
            to: context,
            schedules: index(active: [scheduleA: ruleA])
        )

        #expect(result.scheduleID == scheduleA)
    }

    @Test func otherScheduleLinkedRuleIsSkippedWhenTransactionAlreadyHasASchedule() {
        let attached = scheduleOwnedRule(id: ruleA, scheduleID: scheduleA, date: "2026-08-11")
        let other = scheduleOwnedRule(
            id: ruleB,
            scheduleID: scheduleB,
            date: "2026-08-11",
            extraActions: [RuleAction(operation: "set", field: "notes", value: .string("other"))]
        )
        var context = makeContext(date: date("2026-08-11"))
        context.scheduleID = scheduleA

        let result = RuleConditionEvaluator.applying(
            [attached, other],
            to: context,
            schedules: index(active: [scheduleA: ruleA, scheduleB: ruleB])
        )

        #expect(result.scheduleID == scheduleA)
        #expect(result.notes == "start")
    }

    @Test func completedTombstonedAndMissingSchedulesDoNotForceExecute() {
        let noteAction = RuleAction(operation: "set", field: "notes", value: .string("ran"))
        let completed = scheduleOwnedRule(
            id: "completed-rule",
            scheduleID: "completed-sched",
            extraActions: [noteAction],
            isCompleted: true
        )
        let tombstoned = scheduleOwnedRule(
            id: "tombstoned-rule",
            scheduleID: "tombstoned-sched",
            extraActions: [noteAction]
        )
        let missing = scheduleOwnedRule(
            id: "missing-rule",
            scheduleID: "missing-sched",
            date: "2026-08-11",
            extraActions: [noteAction]
        )
        let schedules = RuleScheduleIndex(
            ruleIDByScheduleID: [:],
            completedRuleIDs: ["completed-rule", "tombstoned-rule"]
        )
        var attachedToMissing = makeContext(date: date("2026-01-01"))
        attachedToMissing.scheduleID = "missing-sched"

        let completedResult = RuleConditionEvaluator.applying(
            [completed],
            to: makeContext(date: date("2026-08-11")),
            schedules: schedules
        )
        let tombstonedResult = RuleConditionEvaluator.applying(
            [tombstoned],
            to: makeContext(date: date("2026-08-11")),
            schedules: schedules
        )
        let missingResult = RuleConditionEvaluator.applying(
            [missing],
            to: attachedToMissing,
            schedules: schedules
        )

        #expect(completedResult.notes == "start")
        #expect(tombstonedResult.notes == "start")
        #expect(missingResult.notes == "start")
        #expect(missingResult.scheduleID == "missing-sched")
    }

    @Test func unsupportedSiblingActionBlocksEveryActionIncludingLinkSchedule() {
        let rule = scheduleOwnedRule(
            id: ruleA,
            scheduleID: scheduleA,
            extraActions: [RuleAction(operation: "delete-transaction", value: .string(""))]
        )

        let result = RuleConditionEvaluator.applying(
            [rule],
            to: makeContext(date: date("2026-08-11")),
            schedules: index(active: [scheduleA: ruleA])
        )

        #expect(result.scheduleID == nil)
        #expect(result.categoryID == nil)
    }

    @Test func acctConditionOnAScheduleRuleMatchesAccount() {
        let rule = ManagedRule(
            id: ruleA,
            draft: nil,
            rawStage: nil,
            rawConditionsJSON: """
            [
              {"op":"is","field":"acct","value":"checking"},
              {"op":"is","field":"description","value":"coffee"}
            ]
            """,
            rawActionsJSON: "[{\"op\":\"link-schedule\",\"value\":\"\(scheduleA)\"}]",
            payeeIDs: ["coffee"],
            isCompletedScheduleRule: false
        )

        let result = RuleConditionEvaluator.applying(
            [rule],
            to: makeContext(),
            schedules: index(active: [scheduleA: ruleA])
        )

        #expect(result.scheduleID == scheduleA)
    }

    private func index(active: [String: String], completed: Set<String> = []) -> RuleScheduleIndex {
        RuleScheduleIndex(ruleIDByScheduleID: active, completedRuleIDs: completed)
    }

    private func scheduleOwnedRule(
        id: String,
        scheduleID: String,
        date: String = "2026-08-11",
        extraActions: [RuleAction] = [],
        isCompleted: Bool = false
    ) -> ManagedRule {
        let actions = [RuleAction(operation: "link-schedule", value: .string(scheduleID))] + extraActions
        let rawActionsJSON = String(data: try! JSONEncoder().encode(actions), encoding: .utf8) ?? "[]"
        return ManagedRule(
            id: id,
            draft: nil,
            rawStage: nil,
            rawConditionsJSON: """
            [
              {"op":"is","field":"description","value":"coffee"},
              {"op":"is","field":"date","value":"\(date)"}
            ]
            """,
            rawActionsJSON: rawActionsJSON,
            payeeIDs: ["coffee"],
            isCompletedScheduleRule: isCompleted
        )
    }

    private func makeContext(
        date: Date = RuleScheduleRuntimeTests.date("2026-08-11")
    ) -> RuleEvaluationContext {
        RuleEvaluationContext(
            accountID: "checking",
            accountName: "Checking",
            accountIsOffBudget: false,
            amount: -14000,
            categoryID: nil,
            categoryName: nil,
            categoryGroupID: nil,
            categoryGroupName: nil,
            date: date,
            notes: "start",
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            importedPayee: nil,
            cleared: false,
            reconciled: false,
            isTransfer: false,
            isParent: false,
            accountNames: ["checking": "Checking"],
            offBudgetAccountIDs: [],
            categoryNames: ["groceries": "Groceries"],
            categoryGroupsByCategoryID: [:],
            categoryGroupNames: [:],
            payeeNames: ["coffee": "Coffee Shop"]
        )
    }

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private func date(_ value: String) -> Date {
        Self.date(value)
    }
}

extension LocalFirstActualStoreTests {
    @Test func createTransactionPersistsScheduleAttachedByAMatchingRule() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            ALTER TABLE transactions ADD COLUMN schedule TEXT;
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                stage TEXT,
                conditions TEXT,
                actions TEXT,
                conditions_op TEXT DEFAULT 'and',
                tombstone INTEGER DEFAULT 0
            );
            INSERT INTO rules VALUES (
                'internet-rule',
                NULL,
                '[{"op":"is","field":"description","value":"coffee"}]',
                '[{"op":"link-schedule","value":"internet-sched"}]',
                'and',
                0
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY,
                rule TEXT,
                completed INTEGER,
                tombstone INTEGER
            );
            INSERT INTO schedules VALUES ('internet-sched', 'internet-rule', 0, 0);
            """)

        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 8, day: 11),
            amountMinorUnits: -14000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let preview = try await store.previewRules(for: draft, budgetID: "group-1")
        #expect(preview.scheduleID == "internet-sched")

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        #expect(created.schedule == "internet-sched")
    }

    @Test func completedScheduleRuleDoesNotBlockPayeeDeletionOrExecute() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            ALTER TABLE transactions ADD COLUMN schedule TEXT;
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO payees VALUES ('unused-sched', 'Unused Sched', NULL, 0);
            INSERT INTO payee_mapping VALUES ('unused-sched', 'unused-sched');
            INSERT INTO rules VALUES (
                'done-rule',
                '[{"field":"description","op":"is","value":"unused-sched"}]',
                '[{"op":"link-schedule","value":"done-sched"}]',
                0
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY,
                rule TEXT,
                completed INTEGER,
                tombstone INTEGER
            );
            INSERT INTO schedules VALUES ('done-sched', 'done-rule', 1, 0);
            """)

        try await store.refreshPayeeManagementSnapshot(budgetID: "group-1")
        let snapshot = try #require(store.cachedPayeeManagementSnapshot(budgetID: "group-1"))
        #expect(snapshot.payees.first { $0.id == "unused-sched" }?.canDelete == true)

        let preview = try await store.previewRules(
            for: TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 8, day: 11),
                amountMinorUnits: -1000,
                payeeID: "unused-sched",
                payeeName: "Unused Sched",
                categoryID: nil,
                notes: nil,
                cleared: false,
                isTransfer: false
            ),
            budgetID: "group-1"
        )
        #expect(preview.scheduleID == nil)
    }
}
