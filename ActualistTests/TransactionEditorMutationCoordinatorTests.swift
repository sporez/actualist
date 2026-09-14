import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionEditorMutationCoordinatorTests {
    @Test func reconciledEditRequiresReviewThenPassesExactAuthorization() async {
        let review = self.review(target: ["txn"])
        let repository = RecordingTransactionRepository(reconciliationReview: review)
        let coordinator = TransactionEditorMutationCoordinator(transaction: transaction())

        let first = await coordinator.submit(
            validation: .valid,
            draft: draft(),
            budgetID: "budget",
            repository: repository
        )

        #expect(first == .awaitingReview)
        #expect(coordinator.presentation?.intent == .update)
        #expect(coordinator.presentation?.title == "Edit Reconciled Transaction?")
        #expect(coordinator.beginConfirmation())

        let confirmed = await coordinator.confirmPending(
            validation: .valid,
            draft: draft(),
            date: Date(timeIntervalSince1970: 1_783_070_400),
            budgetID: "budget",
            repository: repository,
            deleteReview: TransactionRuleDeleteReview(),
            didMutate: {}
        )

        #expect(confirmed == .saved)
        #expect(await repository.recordedUpdateAuthorizations().count == 2)
        #expect(await repository.recordedUpdateAuthorizations().last! == review.authorization)
    }

    @Test func reconciledClearRequestsUnlockAndPreservesClearedState() async throws {
        let review = self.review(target: ["txn", "child"])
        let repository = RecordingTransactionRepository(reconciliationReview: review)
        let coordinator = TransactionEditorMutationCoordinator(transaction: transaction())

        let displayedCleared = try await coordinator.requestClearedChange(
            false,
            budgetID: "budget",
            repository: repository
        )

        #expect(displayedCleared)
        #expect(coordinator.presentation?.intent == .unlock)
        #expect(coordinator.presentation?.message.contains("keeps the transaction cleared") == true)
        #expect(coordinator.beginConfirmation())

        let outcome = await coordinator.confirmPending(
            validation: .valid,
            draft: nil,
            date: Date(timeIntervalSince1970: 1_783_070_400),
            budgetID: "budget",
            repository: repository,
            deleteReview: TransactionRuleDeleteReview(),
            didMutate: {}
        )

        #expect(outcome == .unlocked)
        #expect(!coordinator.isTransactionReconciled)
        #expect(await repository.recordedUnlockTransactionIDs() == ["txn"])
    }

    @Test func ruleDeleteChainsIntoReconciledWarningBeforeDeletion() async {
        let review = self.review(target: [], paired: ["paired"])
        let repository = RecordingTransactionRepository(reconciliationReview: review)
        let coordinator = TransactionEditorMutationCoordinator(transaction: transaction())
        let ruleDelete = TransactionRuleDeleteReview()
        ruleDelete.consider(TransactionRulePreview(
            categoryID: nil,
            notes: nil,
            deletesTransaction: true
        ))

        let first = await coordinator.confirmRuleDelete(
            date: Date(timeIntervalSince1970: 1_783_070_400),
            budgetID: "budget",
            repository: repository,
            deleteReview: ruleDelete,
            didDelete: {}
        )

        #expect(first == .awaitingReview)
        #expect(coordinator.presentation?.intent == .ruleDelete)
        #expect(coordinator.presentation?.message.contains("other side of this transfer") == true)
        #expect(coordinator.beginConfirmation())

        let confirmed = await coordinator.confirmPending(
            validation: .valid,
            draft: draft(),
            date: Date(timeIntervalSince1970: 1_783_070_400),
            budgetID: "budget",
            repository: repository,
            deleteReview: ruleDelete,
            didMutate: {}
        )

        #expect(confirmed == .saved)
        #expect(await repository.recordedDeleteAuthorizations().last! == review.authorization)
    }

    private func review(
        target: [String],
        paired: [String] = []
    ) -> ReconciledTransactionMutationReview {
        ReconciledTransactionMutationReview(
            transactionID: "txn",
            targetReconciledTransactionIDs: target,
            pairedReconciledTransactionIDs: paired
        )
    }

    private func transaction() -> ActualTransaction {
        ActualTransaction(
            id: "txn",
            account: "checking",
            date: "2026-06-14",
            amount: -1_234,
            payee: "coffee",
            payeeName: "Coffee Shop",
            importedPayee: nil,
            category: "groceries",
            notes: nil,
            cleared: .bool(true),
            reconciled: true
        )
    }

    private func draft() -> TransactionDraft {
        var draft = TransactionDraft(
            accountID: "checking",
            date: Date(timeIntervalSince1970: 1_783_070_400),
            amountMinorUnits: -1_234,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "Edited",
            cleared: true,
            isTransfer: false
        )
        draft.reconciled = true
        return draft
    }
}
