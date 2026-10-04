import Foundation

/// A categorize the store refused until the user confirms the reconciled rows
/// it would change. Holds exactly what the confirmed re-submit needs; the
/// authorizations are identity-bound, so the store revalidates them at commit.
struct UncategorizedReconciledCategorization: Hashable, Sendable {
    enum Scope: Hashable, Sendable {
        case single(ActualTransaction)
        case selection
    }

    let scope: Scope
    let categoryID: String
    let month: String?
    let reviews: [ReconciledTransactionMutationReview]

    var authorizations: [String: ReconciledTransactionMutationAuthorization] {
        Dictionary(
            reviews.map { ($0.transactionID, $0.authorization) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var presentation: ReconciledTransactionMutationPresentation? {
        guard let first = reviews.first else { return nil }
        let single = ReconciledTransactionMutationPresentation.make(review: first, intent: .categorize)
        guard reviews.count > 1 else { return single }
        return ReconciledTransactionMutationPresentation(
            review: first,
            intent: .categorize,
            title: single.title,
            message: "Some of the selected transactions are reconciled. Categorizing them can change previously balanced accounts.",
            confirmationTitle: "Categorize Transactions"
        )
    }
}
