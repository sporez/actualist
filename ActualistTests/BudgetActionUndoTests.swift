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
        status: BudgetActionStatus = .applied
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
            source: .ui
        )
    }

    private func assignRecord(
        before: Int = 50_000,
        after: Int = 62_500,
        status: BudgetActionStatus = .applied
    ) -> BudgetActionRecord {
        let assign = AssignBudgetAction(month: "2026-07", categoryID: "groceries", before: before, after: after)
        return makeRecord(
            inverse: .assign(assign),
            summary: .assign(assign),
            affectedCategoryIDs: ["groceries"],
            status: status
        )
    }

    @Test func assignStillAtAfterRestoresBefore() {
        let record = assignRecord()
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 62_500]
        )
        #expect(evaluation == .clean(targets: ["groceries": 50_000]))
    }

    @Test func assignWithNewerCellChangeIsBlocked() {
        let record = assignRecord()
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 65_000]
        )
        #expect(evaluation == .blocked(.changedSinceApplied))
    }

    @Test func assignWithDeletedCategoryIsBlocked() {
        let record = assignRecord()
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": nil]
        )
        #expect(evaluation == .blocked(.categoryMissing))
    }

    @Test func undoneRecordIsNotUndoableAgain() {
        let record = assignRecord(status: .undone)
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 62_500]
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
            liveBudgeted: ["groceries": 45_000, "dining": 10_500]
        )
        #expect(clean == .clean(targets: ["groceries": 50_000, "dining": 5_000]))

        let changed = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 44_000, "dining": 10_500]
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
            liveBudgeted: ["groceries": 45_000, "dining": nil]
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
            liveBudgeted: ["utilities": 30_000, "subscriptions": 4_500]
        )
        #expect(clean == .clean(targets: ["utilities": 0, "subscriptions": 2_000]))

        // One category later assigned by hand blocks the whole gesture.
        let changed = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["utilities": 30_000, "subscriptions": 6_000]
        )
        #expect(changed == .blocked(.changedSinceApplied))
    }

    @Test func restoringARecordedAmountPastTheSupportedRangeIsBlocked() {
        let record = assignRecord(before: Money.maximumUserAmountMinorUnits + 1, after: 0)
        let evaluation = BudgetActionUndo.evaluate(
            record: record,
            liveBudgeted: ["groceries": 0]
        )
        #expect(evaluation == .blocked(.amountOutOfRange))
    }
}
