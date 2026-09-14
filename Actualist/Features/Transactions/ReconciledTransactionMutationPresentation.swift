import Foundation

enum ReconciledTransactionMutationIntent: Hashable, Sendable {
    case update
    case ruleDelete
    case delete
    case unlock
}

struct ReconciledTransactionMutationPresentation: Hashable, Sendable {
    let review: ReconciledTransactionMutationReview
    let intent: ReconciledTransactionMutationIntent
    let title: String
    let message: String
    let confirmationTitle: String

    static func make(
        review: ReconciledTransactionMutationReview,
        intent: ReconciledTransactionMutationIntent
    ) -> Self {
        Self(
            review: review,
            intent: intent,
            title: title(for: intent),
            message: message(for: review, intent: intent),
            confirmationTitle: confirmationTitle(for: intent)
        )
    }

    private static func title(for intent: ReconciledTransactionMutationIntent) -> String {
        switch intent {
        case .update:
            "Edit Reconciled Transaction?"
        case .ruleDelete, .delete:
            "Delete Reconciled Transaction?"
        case .unlock:
            "Unlock Reconciled Transaction?"
        }
    }

    private static func confirmationTitle(
        for intent: ReconciledTransactionMutationIntent
    ) -> String {
        switch intent {
        case .update:
            "Edit Transaction"
        case .ruleDelete, .delete:
            "Delete Transaction"
        case .unlock:
            "Unlock Transaction"
        }
    }

    private static func message(
        for review: ReconciledTransactionMutationReview,
        intent: ReconciledTransactionMutationIntent
    ) -> String {
        if intent == .unlock {
            return "This keeps the transaction cleared and removes its reconciliation lock. You can then edit it normally."
        }

        let action = intent == .update ? "Editing" : "Deleting"
        if review.targetRequiresUnlock && review.includesPairedTransfer {
            return "This transaction and the other side of its transfer include reconciled data. \(action) it can change previously balanced accounts."
        }
        if review.includesPairedTransfer {
            return "The other side of this transfer is reconciled. \(action) this transaction can change a previously balanced account."
        }
        if review.targetReconciledTransactionIDs.count > 1 {
            return "This split transaction includes reconciled entries. \(action) it can change a previously balanced account."
        }
        return "This transaction has been reconciled. \(action) it can change a previously balanced account."
    }
}
