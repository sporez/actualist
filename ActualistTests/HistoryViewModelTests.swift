import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    private func assignGroceries(
        _ store: LocalFirstActualStore,
        budgeted: Int
    ) async throws {
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: budgeted,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
    }

    @Test func loadedRowsOfferUndoOnlyOnTheNewestAppliedGesture() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        try await assignGroceries(bundle.store, budgeted: 61_000)
        try await assignGroceries(bundle.store, budgeted: 63_000)

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.count == 2)
        #expect(viewModel.rows[0].canUndo)
        #expect(!viewModel.rows[1].canUndo)
        #expect(viewModel.rows[0].title.contains("to Groceries"))
        #expect(viewModel.rows[0].amountText == "+20.00")
        #expect(viewModel.rows[0].visual == .assign)
    }

    @Test func moveRowDescribesFromAndTo() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        _ = try await bundle.store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: "dining",
                amount: 5_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)

        let row = try #require(viewModel.rows.first)
        #expect(row.title == "Moved 50.00")
        #expect(row.detail.contains("Groceries → Dining"))
        #expect(row.visual == .move)
    }

    @Test func templateRowUsesTheModeName() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        _ = try await bundle.store.applyBudgetTemplateAndRefresh(
            command: .category("utilities"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)

        let row = try #require(viewModel.rows.first)
        #expect(row.title == "Applied Templates Overwrite")
        #expect(row.detail.contains("1 category"))
        #expect(row.visual == .template)
    }

    @Test func undoReviewCommitsAndMarksTheRowUndone() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        try await assignGroceries(bundle.store, budgeted: 62_500)

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)
        let row = try #require(viewModel.rows.first)

        await viewModel.beginUndo(row, using: appState)
        let review = try #require(viewModel.activeReview)
        #expect(review.isUndoable)
        #expect(review.gestureSummary.contains("625.00"))
        #expect(review.entries.count == 1)
        #expect(review.entries.first?.currentText == "625.00")
        #expect(review.entries.first?.proposedText == "500.00")

        await viewModel.confirmUndo(using: appState)

        #expect(viewModel.activeReview == nil)
        #expect(viewModel.undoFailureMessage == nil)
        let undoneRow = try #require(viewModel.rows.first)
        #expect(undoneRow.isUndone)
        #expect(!undoneRow.canUndo)
        #expect(undoneRow.detail.contains("Undone"))
        let loaded = try await bundle.store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(
            loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 50_000)
    }

    @Test func beginUndoOnABlockedGestureShowsTheReasonWithoutConfirm() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        try await assignGroceries(bundle.store, budgeted: 62_500)

        // A peer-style write that History never grouped.
        let database = try await bundle.store.requireDatabase(for: "group-1")
        var builder = LocalFirstSyncMessageBuilder()
        let untracked = try await database.assignCategoryBudgetMessages(
            categoryID: "groceries",
            budgeted: 65_000,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(untracked)

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)
        let row = try #require(viewModel.rows.first)

        await viewModel.beginUndo(row, using: appState)
        let review = try #require(viewModel.activeReview)
        #expect(!review.isUndoable)
        #expect(review.blockReason?.contains("Undo would overwrite the newer change") == true)
        #expect(review.entries.isEmpty)

        viewModel.cancelUndo()
        #expect(viewModel.activeReview == nil)
        #expect(viewModel.undoFailureMessage == nil)
    }

    @Test func staleCommitBecomesAnUndoFailureMessageAndWritesNothing() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        try await assignGroceries(bundle.store, budgeted: 62_500)

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)
        let row = try #require(viewModel.rows.first)
        await viewModel.beginUndo(row, using: appState)
        #expect(viewModel.activeReview != nil)

        // The cell moves after the review opened; the commit re-checks.
        let database = try await bundle.store.requireDatabase(for: "group-1")
        var builder = LocalFirstSyncMessageBuilder()
        let racing = try await database.assignCategoryBudgetMessages(
            categoryID: "groceries",
            budgeted: 66_000,
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(racing)

        await viewModel.confirmUndo(using: appState)

        #expect(viewModel.activeReview == nil)
        #expect(viewModel.undoFailureMessage?.contains("Undo would overwrite the newer change") == true)
        viewModel.dismissUndoFailure()
        #expect(viewModel.undoFailureMessage == nil)
        #expect(viewModel.rows.first?.isUndone == false)
    }

    @Test func privacyModeRandomizesRowAmountsAndNames() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        try await assignGroceries(bundle.store, budgeted: 62_500)
        appState.updateRandomizedDisplayValuesEnabled(true)

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)

        let row = try #require(viewModel.rows.first)
        #expect(!row.title.contains("625.00"))
        #expect(!row.title.contains("Groceries"))
        #expect(row.amountText != "+125.00")
        #expect(row.amountText != nil)
    }

    @Test func createTransactionRowDescribesThePayeeAndAmount() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        _ = try await bundle.store.createTransactionAndRefresh(
            TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 7, day: 8),
                amountMinorUnits: -450,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: "groceries",
                notes: nil,
                cleared: false,
                isTransfer: false
            ),
            budgetID: "group-1"
        ) {}

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)

        let row = try #require(viewModel.rows.first)
        #expect(row.visual == .createTransaction)
        #expect(row.title.contains("Coffee Shop"))
        #expect(row.canUndo)
    }

    @Test func emptyHistoryLoadsEmptyRows() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)

        let viewModel = HistoryViewModel()
        await viewModel.load(using: appState)

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.isEmpty)
    }
}
