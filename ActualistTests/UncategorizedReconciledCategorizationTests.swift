import Foundation
import Testing
@testable import Actualist

/// Audit 2.14 (D7k): the Uncategorized screen asks for the same confirmation
/// as an edit before categorizing a reconciled row.
@MainActor
struct UncategorizedReconciledCategorizationTests {
    private func loaded(_ transactions: [ActualTransaction]) -> LoadedUncategorizedTransactions {
        LoadedUncategorizedTransactions(
            transactions: transactions,
            accountNames: ["checking": "Checking"],
            categoryNames: [:],
            payeeNames: ["store": "Corner Store"],
            transferPayeeIDs: [],
            categoryGroups: []
        )
    }

    private func review(_ id: String) -> ReconciledTransactionMutationReview {
        ReconciledTransactionMutationReview(
            transactionID: id,
            targetReconciledTransactionIDs: [id],
            pairedReconciledTransactionIDs: []
        )
    }

    private func makeModel(
        _ transactions: [ActualTransaction],
        reconciled: [String]
    ) async -> (UncategorizedTransactionsViewModel, UncategorizedRecordingTransactionRepository) {
        let repository = UncategorizedRecordingTransactionRepository(loaded: loaded(transactions))
        repository.reconciledReviews = Dictionary(uniqueKeysWithValues: reconciled.map { ($0, review($0)) })
        let model = UncategorizedTransactionsViewModel()
        await model.load(budgetID: "budget", month: "2026-06", repository: repository)
        return (model, repository)
    }

    @Test func reconciledRowPresentsTheReviewAndWritesNothing() async throws {
        let row = UncategorizedTransactionsViewModelTests.transaction(id: "txn1")
        let (model, repository) = await makeModel([row], reconciled: ["txn1"])

        let result = await model.categorize(
            row, categoryID: "groceries", budgetID: "budget",
            monthForRemainingRefresh: "2026-06", repository: repository
        )

        #expect(result == .failed)
        let pending = try #require(model.reconciledCategorization)
        #expect(pending.presentation?.title == "Categorize Reconciled Transaction?")
        #expect(pending.presentation?.confirmationTitle == "Categorize Transaction")
        #expect(pending.reviews == [review("txn1")])
        #expect(model.errorMessage == nil)
        #expect(model.transactions.map(\.rowID) == ["txn1"])
        #expect(await repository.recordedCategoryID() == nil)
    }

    @Test func confirmingResubmitsWithTheReviewedAuthorization() async throws {
        let row = UncategorizedTransactionsViewModelTests.transaction(id: "txn1")
        let (model, repository) = await makeModel([row], reconciled: ["txn1"])
        _ = await model.categorize(
            row, categoryID: "groceries", budgetID: "budget",
            monthForRemainingRefresh: "2026-06", repository: repository
        )
        let pending = try #require(model.reconciledCategorization)

        let result = await model.confirmReconciledCategorization(
            pending, budgetID: "budget", repository: repository
        )

        #expect(result.didChange)
        #expect(model.reconciledCategorization == nil)
        #expect(await repository.recordedCategoryID() == "groceries")
        #expect(repository.submittedAuthorizations.last == ["txn1": review("txn1").authorization])
    }

    @Test func cancellingWritesNothingAndClearsTheReview() async throws {
        let row = UncategorizedTransactionsViewModelTests.transaction(id: "txn1")
        let (model, repository) = await makeModel([row], reconciled: ["txn1"])
        _ = await model.categorize(
            row, categoryID: "groceries", budgetID: "budget",
            monthForRemainingRefresh: "2026-06", repository: repository
        )

        model.dismissReconciledCategorization()

        #expect(model.reconciledCategorization == nil)
        #expect(await repository.recordedCategoryID() == nil)
        #expect(model.transactions.map(\.rowID) == ["txn1"])
    }

    @Test func bulkCategorizeAsksOnceForEveryReconciledSelectedRow() async throws {
        let rows = ["a", "b", "c"].map { UncategorizedTransactionsViewModelTests.transaction(id: $0) }
        let (model, repository) = await makeModel(rows, reconciled: ["a", "c"])
        model.beginSelection()
        rows.forEach(model.toggleSelection)
        let option = TransactionEditorCategoryOption(id: "groceries", title: "Groceries", amount: nil, valueText: nil)

        let first = await model.categorizeSelection(
            as: option, month: "2026-06", budgetID: "budget", repository: repository
        )

        #expect(first == .failed)
        let pending = try #require(model.reconciledCategorization)
        #expect(pending.reviews.map(\.transactionID) == ["a", "c"])
        #expect(pending.presentation?.message.hasPrefix("Some of the selected") == true)
        #expect(await repository.recordedCategoryID() == nil)

        let second = await model.confirmReconciledCategorization(
            pending, budgetID: "budget", repository: repository
        )

        #expect(second.didChange)
        #expect(await repository.recordedTransactionIDs() == ["a", "b", "c"])
        #expect(model.reconciledCategorization == nil)
    }
}
