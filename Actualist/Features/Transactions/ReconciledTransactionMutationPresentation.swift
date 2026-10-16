import Foundation

enum ReconciledTransactionMutationIntent: Hashable, Sendable {
    case update
    case ruleDelete
    case delete
    case categorize
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
        case .categorize:
            "Categorize Reconciled Transaction?"
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
        case .categorize:
            "Categorize Transaction"
        case .unlock:
            "Unlock Transaction"
        }
    }

    private static func message(
        for review: ReconciledTransactionMutationReview,
        intent: ReconciledTransactionMutationIntent
    ) -> String {
        if intent == .unlock {
            return "The transaction stays cleared but is no longer locked, so you can edit it."
        }

        let action = switch intent {
        case .update: "Editing"
        case .categorize: "Categorizing"
        default: "Deleting"
        }
        if review.targetRequiresUnlock && review.includesPairedTransfer {
            return "This transaction and the other side of its transfer are reconciled. \(action) it may change balances you already reconciled."
        }
        if review.includesPairedTransfer {
            return "The other side of this transfer is reconciled. \(action) this transaction may change a balance you already reconciled."
        }
        if review.targetReconciledTransactionIDs.count > 1 {
            return "This split transaction includes reconciled parts. \(action) it may change a balance you already reconciled."
        }
        return "This transaction is reconciled. \(action) it may change a balance you already reconciled."
    }
}
