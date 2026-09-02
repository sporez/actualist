import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func assignRecordsOneActionLogRowWithInverseFacts() async throws {
        let store = try await makeOpenedWritableStore()

        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        let row = try #require(rows.only)
        #expect(row.kind == .assign)
        #expect(row.status == .applied)
        #expect(row.source == .ui)
        #expect(row.month == "2026-07")
        #expect(row.affectedCategoryIDs == ["groceries"])
        #expect(row.summary == .assign(AssignBudgetAction(
            month: "2026-07",
            categoryID: "groceries",
            before: 50_000,
            after: 62_500
        )))
        #expect(row.inverse == .assign(AssignBudgetAction(
            month: "2026-07",
            categoryID: "groceries",
            before: 50_000,
            after: 62_500
        )))
        let start = try #require(row.forwardTimestampStart)
        let end = try #require(row.forwardTimestampEnd)
        #expect(start <= end)
    }

    @Test func moveRecordsOneRowWithLegsAndPreviousBudgeted() async throws {
        let store = try await makeOpenedWritableStore()

        _ = try await store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: "dining",
                amount: 5_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        let row = try #require(rows.only)
        #expect(row.kind == .move)
        #expect(row.source == .ui)
        #expect(row.affectedCategoryIDs == ["dining", "groceries"])
        let legs = [BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 5_000)]
        #expect(row.summary == .move(MoveBudgetAction(month: "2026-07", legs: legs)))
        #expect(row.inverse == .move(MoveBudgetActionInverse(
            month: "2026-07",
            legs: legs,
            previousBudgeted: ["groceries": 50_000, "dining": 0]
        )))
    }

    @Test func multiCommandMoveIsOneLogRow() async throws {
        let store = try await makeOpenedWritableStore()

        _ = try await store.moveMoneyAndRefresh(
            commands: [
                BudgetMoveMoneyCommand(fromCategoryID: "groceries", toCategoryID: "dining", amount: 500),
                BudgetMoveMoneyCommand(fromCategoryID: "utilities", toCategoryID: "dining", amount: 250)
            ],
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        let row = try #require(rows.only)
        #expect(row.kind == .move)
        #expect(row.affectedCategoryIDs == ["dining", "groceries", "utilities"])
        guard case .move(let move) = row.summary else {
            Issue.record("expected move summary")
            return
        }
        #expect(move.legs.count == 2)
        guard case .move(let inverse) = row.inverse else {
            Issue.record("expected move inverse")
            return
        }
        #expect(inverse.previousBudgeted == ["groceries": 50_000, "utilities": 0, "dining": 0])
    }

    @Test func shortcutWritesRecordShortcutsSource() async throws {
        let store = try await makeOpenedWritableStore()

        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 61_000,
            budgetID: "group-1",
            month: "2026-07",
            actionSource: .shortcuts
        ) {}

        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        #expect(rows.only?.source == .shortcuts)
    }

    @Test func failedLogInsertRollsBackTheWholeCommit() async throws {
        let store = try await makeOpenedWritableStore()
        let database = try await store.requireDatabase(for: "group-1")

        var firstBuilder = LocalFirstSyncMessageBuilder()
        let first = try await database.assignCategoryBudgetMessages(
            categoryID: "groceries",
            budgeted: 60_000,
            month: "2026-07",
            builder: &firstBuilder
        )
        try await database.commitUserAction(
            first,
            descriptor: .assign(month: "2026-07", categoryID: "groceries", budgeted: 60_000),
            source: .ui,
            actionID: "action-1"
        )
        let pendingBefore = try await store.pendingLocalSyncMessageCount(budgetID: "group-1")
        #expect(try await database.recentBudgetActions().count == 1)

        var secondBuilder = LocalFirstSyncMessageBuilder()
        let second = try await database.assignCategoryBudgetMessages(
            categoryID: "groceries",
            budgeted: 70_000,
            month: "2026-07",
            builder: &secondBuilder
        )
        await #expect(throws: (any Error).self) {
            try await database.commitUserAction(
                second,
                descriptor: .assign(month: "2026-07", categoryID: "groceries", budgeted: 70_000),
                source: .ui,
                actionID: "action-1"
            )
        }

        // The duplicate log id must roll back the CRDT write, the outbox
        // entries, and any second log row: no orphan write without its row.
        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(
            loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 60_000)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingBefore)
        #expect(try await database.recentBudgetActions().count == 1)
    }

    @Test func retentionKeepsNewest25MoneyFlowGestures() async throws {
        let store = try await makeOpenedWritableStore()
        let database = try await store.requireDatabase(for: "group-1")

        for index in 1...30 {
            let month = index.isMultiple(of: 2) ? "2026-07" : "2026-08"
            var builder = LocalFirstSyncMessageBuilder()
            let messages = try await database.assignCategoryBudgetMessages(
                categoryID: "groceries",
                budgeted: 10_000 + index,
                month: month,
                builder: &builder
            )
            try await database.commitUserAction(
                messages,
                descriptor: .assign(month: month, categoryID: "groceries", budgeted: 10_000 + index),
                source: .ui,
                actionID: "action-\(index)",
                now: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }

        let rows = try await database.recentBudgetActions(limit: 100)
        #expect(rows.count == 25)
        #expect(rows.first?.id == "action-30")
        #expect(rows.last?.id == "action-6")
    }

    @Test func recentBudgetActionsIsEmptyBeforeTheFirstRecordedWrite() async throws {
        let store = try await makeOpenedWritableStore()
        #expect(try await store.recentBudgetActions(budgetID: "group-1").isEmpty)
    }

    @Test func emptyMoveWritesNoLogRow() async throws {
        let store = try await makeOpenedWritableStore()

        _ = try await store.moveMoneyAndRefresh(
            commands: [],
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        #expect(try await store.recentBudgetActions(budgetID: "group-1").isEmpty)
    }

    @Test func templateApplyRecordsOneRowWithBeforeAndAfter() async throws {
        let store = try await makeOpenedWritableStore()

        _ = try await store.applyBudgetTemplateAndRefresh(
            command: .category("utilities"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        let row = try #require(rows.only)
        #expect(row.kind == .template)
        #expect(row.status == .applied)
        #expect(row.source == .ui)
        #expect(row.month == "2026-07")
        #expect(row.affectedCategoryIDs == ["utilities"])
        let template = TemplateBudgetAction(
            month: "2026-07",
            mode: .overwrite,
            entries: [BudgetTemplateAssignmentFact(categoryID: "utilities", before: 0, after: 30_000)]
        )
        #expect(row.summary == .template(template))
        #expect(row.inverse == .template(template))
    }

    @Test func undoAssignRestoresBeforeAndMarksRowUndoneWithoutANewRow() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let row = try #require(try await store.recentBudgetActions(budgetID: "group-1").only)
        let pendingBefore = try await store.pendingLocalSyncMessageCount(budgetID: "group-1")

        try await store.undoBudgetActionAndRefresh(actionID: row.id, budgetID: "group-1")

        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(
            loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 50_000)
        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        let undone = try #require(rows.only)
        #expect(undone.id == row.id)
        #expect(undone.status == .undone)
        // The compensating write syncs like any local write.
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > pendingBefore)
    }

    @Test func undoMoveRestoresEveryLegAtomically() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.moveMoneyAndRefresh(
            commands: [
                BudgetMoveMoneyCommand(fromCategoryID: "groceries", toCategoryID: "dining", amount: 5_000),
                BudgetMoveMoneyCommand(fromCategoryID: nil, toCategoryID: "dining", amount: 500)
            ],
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let row = try #require(try await store.recentBudgetActions(budgetID: "group-1").only)

        try await store.undoBudgetActionAndRefresh(actionID: row.id, budgetID: "group-1")

        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let categories = Dictionary(
            uniqueKeysWithValues: loaded.month.categoryGroups.flatMap(\.categories).map { ($0.id, $0.budgeted) }
        )
        #expect(categories["groceries"] == 50_000)
        #expect(categories["dining"] == 0)
        #expect(try await store.recentBudgetActions(budgetID: "group-1").only?.status == .undone)
    }

    @Test func undoOfAnOlderAppliedRowIsRefusedLIFO() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 61_000,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 63_000,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        #expect(rows.count == 2)
        let older = try #require(rows.last)

        await #expect(throws: LocalFirstError.actionUndoBlocked("Undo the newest action before this one.")) {
            try await store.undoBudgetActionAndRefresh(actionID: older.id, budgetID: "group-1")
        }

        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(
            loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 63_000)
        #expect(try await store.recentBudgetActions(budgetID: "group-1").allSatisfy { $0.status == .applied })
    }

    @Test func undoNewestThenPreviousRestoresInReverseOrder() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 61_000,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 63_000,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        var rows = try await store.recentBudgetActions(budgetID: "group-1")

        try await store.undoBudgetActionAndRefresh(actionID: rows[0].id, budgetID: "group-1")
        try await store.undoBudgetActionAndRefresh(actionID: rows[1].id, budgetID: "group-1")

        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(
            loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 50_000)
        rows = try await store.recentBudgetActions(budgetID: "group-1")
        #expect(rows.allSatisfy { $0.status == .undone })
    }

    @Test func undoIsBlockedWhenAnUntrackedChangeOwnsTheCell() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let row = try #require(try await store.recentBudgetActions(budgetID: "group-1").only)

        // A remote-style or peer write that History never grouped: the live
        // cell no longer matches the recorded after-state.
        let database = try await store.requireDatabase(for: "group-1")
        var builder = LocalFirstSyncMessageBuilder()
        let untracked = try await database.assignCategoryBudgetMessages(
            categoryID: "groceries",
            budgeted: 65_000,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(untracked)

        await #expect(throws: LocalFirstError.actionUndoBlocked(
            "Something changed a category after this action. Undo would overwrite the newer change, so it was refused."
        )) {
            try await store.undoBudgetActionAndRefresh(actionID: row.id, budgetID: "group-1")
        }

        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        #expect(rows.only?.status == .applied)
        let database2 = try await store.requireDatabase(for: "group-1")
        let preview = try await database2.actionUndoPreview(record: row)
        #expect(preview.block == .changedSinceApplied)
        #expect(preview.entries.isEmpty)
    }

    @Test func undoTemplateRestoresEveryAssignedCategory() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.applyBudgetTemplateAndRefresh(
            command: .category("utilities"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let row = try #require(try await store.recentBudgetActions(budgetID: "group-1").only)

        try await store.undoBudgetActionAndRefresh(actionID: row.id, budgetID: "group-1")

        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let utilities = try #require(
            loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )
        #expect(utilities.budgeted == 0)
        #expect(try await store.recentBudgetActions(budgetID: "group-1").only?.status == .undone)
    }

    @Test func undoPreviewShowsCurrentAndProposedAmounts() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let row = try #require(try await store.recentBudgetActions(budgetID: "group-1").only)

        let preview = try await store.budgetActionUndoPreview(actionID: row.id, budgetID: "group-1")
        #expect(preview.isUndoable)
        #expect(preview.month == "2026-07")
        #expect(preview.entries == [
            BudgetActionUndoPreview.Entry(categoryID: "groceries", current: 62_500, proposed: 50_000)
        ])
    }

    @Test func undoOfAnAlreadyUndoneRowIsRefused() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let row = try #require(try await store.recentBudgetActions(budgetID: "group-1").only)
        try await store.undoBudgetActionAndRefresh(actionID: row.id, budgetID: "group-1")

        await #expect(throws: LocalFirstError.actionUndoBlocked("This action was already undone.")) {
            try await store.undoBudgetActionAndRefresh(actionID: row.id, budgetID: "group-1")
        }
        let preview = try await store.budgetActionUndoPreview(actionID: row.id, budgetID: "group-1")
        #expect(preview.block == .alreadyUndone)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
