import Foundation

struct ReconciledTransactionMutationAuthorization: Hashable, Sendable {
    let transactionID: String
    let targetReconciledTransactionIDs: [String]
    let pairedReconciledTransactionIDs: [String]
}

/// Revalidates a transaction-bound confirmation at the final SQLite write
/// boundary. A nil authorization is deliberate: it proves no reconciled rows
/// were present when the mutation was prepared and must still be true at commit.
struct ReconciledTransactionMutationPrecondition: Hashable, Sendable {
    let transactionID: String
    let authorization: ReconciledTransactionMutationAuthorization?
}

struct ReconciledTransactionMutationReview: Hashable, Sendable {
    let transactionID: String
    let targetReconciledTransactionIDs: [String]
    let pairedReconciledTransactionIDs: [String]

    var authorization: ReconciledTransactionMutationAuthorization {
        ReconciledTransactionMutationAuthorization(
            transactionID: transactionID,
            targetReconciledTransactionIDs: targetReconciledTransactionIDs,
            pairedReconciledTransactionIDs: pairedReconciledTransactionIDs
        )
    }

    var targetRequiresUnlock: Bool {
        !targetReconciledTransactionIDs.isEmpty
    }

    var includesPairedTransfer: Bool {
        !pairedReconciledTransactionIDs.isEmpty
    }
}

enum ReconciledTransactionMutationError: LocalizedError, Equatable {
    case confirmationRequired(ReconciledTransactionMutationReview)

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            "Review the reconciled transaction warning before changing this transaction."
        }
    }
}
