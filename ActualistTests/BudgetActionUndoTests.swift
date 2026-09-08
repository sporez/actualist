import Foundation
import Testing
@testable import Actualist

/// Pure conflict-check coverage for `BudgetActionUndo.evaluate`: clean vs
/// blocked for every v1 inverse kind, so later selective undo (Model B) does
/// not have to invent the check.
@Suite struct BudgetActionUndoTests {
    private func makeRecord(
        inverse: BudgetActionInverse,
        summary: BudgetActionSummary,
        affectedCategoryIDs: [String],
        status: BudgetActionStatus = .applied,
        modeIdentity: BudgetModeIdentity? = BudgetModeIdentity(
            storageID: "db-1", table: .envelope, revision: "r1"
        )
    ) -> BudgetActionRecord {
        BudgetActionRecord(
            id: "action-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .assign,
            status: status,
            month: "2026-07",
            summary: summary,
            inverse: inverse,
            affectedCategoryIDs: affectedCategoryIDs,
            forwardTimestampStart: nil,
            forwardTimestampEnd: nil,
            source: .ui,
            modeIdentity: modeIdentity
        )
    }

    private func assignRecord(
        before: Int = 50_000,
        after: Int = 62_500,
        status: BudgetActionStatus = .applied,
        modeIdentity: BudgetModeIdentity? = BudgetModeIdentity(
            storageID: "db-1", table: .envelope, revision: "r1"
        )
    ) -> BudgetActionRecord {
        let assign = AssignBudgetAction(month: "2026-07", categoryID: "groceries", before: before, after: after)
        return makeRecord(
            inverse: .assign(assign),
            summary: .assign(assign),
            affectedCategoryIDs: ["groceries"],
            status: status,
            modeIdentity: modeIdentity
        )
    }

    @Test func assignStillAtAfterRestoresBefore() {
        let record = assignRecord()
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 62_500],
            currentModeIdentity: record.modeIdentity
        )
        #expect(evaluation == .clean(.assignments(targets: ["groceries": 50_000])))
    }

    @Test func budgetUndoRequiresTheExactModeIdentity() {
        var record = assignRecord()
        record.modeIdentity = BudgetModeIdentity(storageID: "db-1", table: .envelope, revision: "r1")

        #expect(BudgetActionUndo.evaluate(
            record: record, liveBudgeted: ["groceries": 62_500], currentModeIdentity: nil
        ) == .blocked(.budgetModeChanged))

        let converted = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 62_500],
            currentModeIdentity: BudgetModeIdentity(storageID: "db-1", table: .tracking, revision: "r2")
        )
        #expect(converted == .blocked(.budgetModeChanged))

        let legacy = BudgetActionUndo.evaluate(
            record: assignRecord(modeIdentity: nil),
            liveBudgeted: ["groceries": 62_500],
            currentModeIdentity: BudgetModeIdentity(storageID: "db-1", table: .envelope, revision: "r1")
        )
        #expect(legacy == .blocked(.budgetModeChanged))
    }

    @Test func transactionUndoDoesNotRequireBudgetModeIdentity() {
        let inverse = CreateTransactionInverse(
            month: "2026-07", primaryTransactionID: "txn-1", transactionIDs: ["txn-1"],
            graph: .simple, createdPayeeID: nil, learning: .empty
        )
        let summary = TransactionBudgetAction(
            month: "2026-07", amount: -450, payeeName: "Coffee", categoryID: "groceries",
            graph: .simple, transactionCount: 1
        )
        let record = makeRecord(
            inverse: .createTransaction(inverse), summary: .createTransaction(summary),
            affectedCategoryIDs: []
        )
        let live = TransactionUndoSnapshot(
            id: "txn-1", accountID: "checking", dateValue: 20260708, amount: -450,
            payeeID: "coffee", categoryID: "groceries", notes: nil, cleared: false,
            tombstone: false, transferID: nil, isParent: false, isChild: false, parentID: nil
        )
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: BudgetModeIdentity(storageID: "db-1", table: .tracking, revision: "r2"),
            liveTransactions: ["txn-1": live]
        )
        #expect(evaluation == .clean(.tombstoneTransactions(
            transactionIDs: ["txn-1"], createdPayeeID: nil, learning: .empty
        )))
    }

    @Test func assignWithNewerCellChangeIsBlocked() {
        let record = assignRecord()
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 65_000],
            currentModeIdentity: record.modeIdentity
        )
        #expect(evaluation == .blocked(.changedSinceApplied))
    }

    @Test func assignWithDeletedCategoryIsBlocked() {
        let record = assignRecord()
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": nil],
            currentModeIdentity: record.modeIdentity
        )
        #expect(evaluation == .blocked(.categoryMissing))
    }

    @Test func undoneRecordIsNotUndoableAgain() {
        let record = assignRecord(status: .undone)
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 62_500],
            currentModeIdentity: record.modeIdentity
        )
        #expect(evaluation == .blocked(.alreadyUndone))
    }

    @Test func moveRestoresEveryLegAgainstExpectedAfterAmounts() {
        let legs = [
            BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 5_000),
            BudgetMoveLeg(fromCategoryID: nil, toCategoryID: "dining", amount: 500)
        ]
        let inverse = MoveBudgetActionInverse(
            month: "2026-07",
            legs: legs,
            previousBudgeted: ["groceries": 50_000, "dining": 5_000]
        )
        let record = makeRecord(
            inverse: .move(inverse),
            summary: .move(MoveBudgetAction(month: "2026-07", legs: legs)),
            affectedCategoryIDs: ["groceries", "dining"]
        )

        // Expected after: groceries 45_000, dining 10_500.
        let clean = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 45_000, "dining": 10_500],
            currentModeIdentity: record.modeIdentity
        )
        #expect(clean == .clean(.assignments(targets: ["groceries": 50_000, "dining": 5_000])))

        let changed = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 44_000, "dining": 10_500],
            currentModeIdentity: record.modeIdentity
        )
        #expect(changed == .blocked(.changedSinceApplied))
    }

    @Test func moveWithOneMissingCategoryBlocksTheWholeGesture() {
        let legs = [BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 5_000)]
        let inverse = MoveBudgetActionInverse(
            month: "2026-07",
            legs: legs,
            previousBudgeted: ["groceries": 50_000, "dining": 0]
        )
        let record = makeRecord(
            inverse: .move(inverse),
            summary: .move(MoveBudgetAction(month: "2026-07", legs: legs)),
            affectedCategoryIDs: ["groceries", "dining"]
        )
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 45_000, "dining": nil],
            currentModeIdentity: record.modeIdentity
        )
        #expect(evaluation == .blocked(.categoryMissing))
    }

    @Test func templateRestoresEveryCategoryOnlyWhenAllStillMatch() {
        let entries = [
            BudgetTemplateAssignmentFact(categoryID: "utilities", before: 0, after: 30_000),
            BudgetTemplateAssignmentFact(categoryID: "subscriptions", before: 2_000, after: 4_500)
        ]
        let template = TemplateBudgetAction(month: "2026-07", mode: .fillEmpty, entries: entries)
        let record = makeRecord(
            inverse: .template(template),
            summary: .template(template),
            affectedCategoryIDs: ["utilities", "subscriptions"]
        )

        let clean = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["utilities": 30_000, "subscriptions": 4_500],
            currentModeIdentity: record.modeIdentity
        )
        #expect(clean == .clean(.assignments(targets: ["utilities": 0, "subscriptions": 2_000])))

        // One category later assigned by hand blocks the whole gesture.
        let changed = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["utilities": 30_000, "subscriptions": 6_000],
            currentModeIdentity: record.modeIdentity
        )
        #expect(changed == .blocked(.changedSinceApplied))
    }

    @Test func createTransactionStillLiveTombstonesTheGraph() {
        let inverse = CreateTransactionInverse(
            month: "2026-07",
            primaryTransactionID: "txn-1",
            transactionIDs: ["txn-1"],
            graph: .simple,
            createdPayeeID: nil,
            learning: .empty
        )
        let summary = TransactionBudgetAction(
            month: "2026-07",
            amount: -450,
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            graph: .simple,
            transactionCount: 1
        )
        let record = makeRecord(
            inverse: .createTransaction(inverse),
            summary: .createTransaction(summary),
            affectedCategoryIDs: ["groceries"]
        )
        let live = TransactionUndoSnapshot(
            id: "txn-1",
            accountID: "checking",
            dateValue: 20260708,
            amount: -450,
            payeeID: "coffee",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            tombstone: false,
            transferID: nil,
            isParent: false,
            isChild: false,
            parentID: nil
        )
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: record.modeIdentity,
            liveTransactions: ["txn-1": live]
        )
        #expect(evaluation == .clean(.tombstoneTransactions(
            transactionIDs: ["txn-1"],
            createdPayeeID: nil,
            learning: .empty
        )))
    }

    @Test func createTransactionAlreadyTombstonedIsBlocked() {
        let inverse = CreateTransactionInverse(
            month: "2026-07",
            primaryTransactionID: "txn-1",
            transactionIDs: ["txn-1"],
            graph: .simple,
            createdPayeeID: nil,
            learning: .empty
        )
        let summary = TransactionBudgetAction(
            month: "2026-07",
            amount: -450,
            payeeName: nil,
            categoryID: nil,
            graph: .simple,
            transactionCount: 1
        )
        let record = makeRecord(
            inverse: .createTransaction(inverse),
            summary: .createTransaction(summary),
            affectedCategoryIDs: []
        )
        var live = TransactionUndoSnapshot(
            id: "txn-1",
            accountID: "checking",
            dateValue: 20260708,
            amount: -450,
            payeeID: "coffee",
            categoryID: nil,
            notes: nil,
            cleared: false,
            tombstone: true,
            transferID: nil,
            isParent: false,
            isChild: false,
            parentID: nil
        )
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: record.modeIdentity,
            liveTransactions: ["txn-1": live]
        )
        #expect(evaluation == .blocked(.alreadyTombstoned))
        live.tombstone = false
        live.isParent = true
        let rewritten = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: record.modeIdentity,
            liveTransactions: ["txn-1": live]
        )
        #expect(rewritten == .blocked(.graphRewritten))
    }

    @Test func deleteTransactionStillTombstonedRestoresIt() {
        let inverse = DeleteTransactionInverse(
            month: "2026-07",
            transactionIDs: ["txn-1"],
            graph: .simple
        )
        let summary = TransactionBudgetAction(
            month: "2026-07",
            amount: -450,
            payeeName: nil,
            categoryID: nil,
            graph: .simple,
            transactionCount: 1
        )
        let record = makeRecord(
            inverse: .deleteTransaction(inverse),
            summary: .deleteTransaction(summary),
            affectedCategoryIDs: []
        )
        let live = TransactionUndoSnapshot(
            id: "txn-1",
            accountID: "checking",
            dateValue: 20260708,
            amount: -450,
            payeeID: "coffee",
            categoryID: nil,
            notes: nil,
            cleared: false,
            tombstone: true,
            transferID: nil,
            isParent: false,
            isChild: false,
            parentID: nil
        )
        let clean = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: record.modeIdentity,
            liveTransactions: ["txn-1": live]
        )
        #expect(clean == .clean(.unTombstoneTransactions(transactionIDs: ["txn-1"])))
        var restored = live
        restored.tombstone = false
        let blocked = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: record.modeIdentity,
            liveTransactions: ["txn-1": restored]
        )
        #expect(blocked == .blocked(.alreadyLive))
    }

    @Test func categorizeSkipsAlreadyChangedItemsAndBlocksWhenNoneRemain() {
        let items = [
            BudgetCategorizeFact(transactionID: "txn-1", beforeCategoryID: nil, afterCategoryID: "groceries"),
            BudgetCategorizeFact(transactionID: "txn-2", beforeCategoryID: nil, afterCategoryID: "groceries")
        ]
        let inverse = CategorizeTransactionInverse(month: "2026-07", items: items, learning: .empty)
        let record = makeRecord(
            inverse: .categorize(inverse),
            summary: .categorize(CategorizeBudgetAction(month: "2026-07", categoryID: "groceries", itemCount: 2)),
            affectedCategoryIDs: ["groceries"]
        )
        func snapshot(_ id: String, category: String?) -> TransactionUndoSnapshot {
            TransactionUndoSnapshot(
                id: id,
                accountID: "checking",
                dateValue: 20260708,
                amount: -100,
                payeeID: "coffee",
                categoryID: category,
                notes: nil,
                cleared: false,
                tombstone: false,
                transferID: nil,
                isParent: false,
                isChild: false,
                parentID: nil
            )
        }
        let mixed = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: record.modeIdentity,
            liveTransactions: [
                "txn-1": snapshot("txn-1", category: "groceries"),
                "txn-2": snapshot("txn-2", category: "dining")
            ]
        )
        #expect(mixed == .clean(.restoreCategories(
            items: [items[0]],
            learning: .empty
        )))
        let allChanged = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: record.modeIdentity,
            liveTransactions: [
                "txn-1": snapshot("txn-1", category: "dining"),
                "txn-2": snapshot("txn-2", category: "dining")
            ]
        )
        #expect(allChanged == .blocked(.transactionChanged))
    }

    @Test func unsafeGraphEditIsLocked() {
        let snapshot = TransactionUndoSnapshot(
            id: "txn-1",
            accountID: "checking",
            dateValue: 20260708,
            amount: -450,
            payeeID: "coffee",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            tombstone: false,
            transferID: nil,
            isParent: true,
            isChild: false,
            parentID: nil
        )
        let inverse = EditTransactionInverse(
            month: "2026-07",
            primaryBefore: snapshot,
            primaryAfter: snapshot,
            relatedBefore: [],
            relatedAfter: [],
            unsafeGraph: true,
            createdPayeeID: nil,
            learning: .empty
        )
        let record = makeRecord(
            inverse: .editTransaction(inverse),
            summary: .editTransaction(EditTransactionBudgetAction(
                month: "2026-07",
                amountBefore: -450,
                amountAfter: -450,
                payeeName: "Coffee Shop",
                graph: .split,
                unsafeGraph: true
            )),
            affectedCategoryIDs: []
        )
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: [:],
            currentModeIdentity: record.modeIdentity,
            liveTransactions: ["txn-1": snapshot]
        )
        #expect(evaluation == .blocked(.graphRewritten))
    }

    @Test func restoringARecordedAmountPastTheSupportedRangeIsBlocked() {
        let record = assignRecord(before: Money.maximumUserAmountMinorUnits + 1, after: 0)
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 0],
            currentModeIdentity: record.modeIdentity
        )
        #expect(evaluation == .blocked(.amountOutOfRange))
    }
}
