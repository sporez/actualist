import Foundation

/// Exact preallocated identities and physical order values retained across
/// duplicate review and commit. Actual transaction ordering is stored as a
/// `Double`, so it must not be rounded to an integer at this boundary.
struct TransactionDuplicateAllocation: Codable, Hashable, Sendable {
    let sourceTransactionID: String
    let duplicateTransactionID: String
    let sortOrder: Double
}

struct TransactionDuplicateReviewRow: Hashable, Sendable, Identifiable {
    let sourceTransactionID: String
    let duplicateTransactionID: String
    let accountID: String
    let date: String
    let amountMinorUnits: Int
    let payeeID: String?
    let categoryID: String?
    let isParent: Bool
    let isChild: Bool
    let parentDuplicateTransactionID: String?
    let transferDuplicateTransactionID: String?
    /// Resolved payee (or transfer counterpart account) name; nil when none.
    var payeeName: String? = nil

    var id: String { duplicateTransactionID }
}

struct TransactionDuplicateGroupReview: Hashable, Sendable, Identifiable {
    /// Stable source identity for one fully connected duplicate operation.
    let id: String
    let selectedTransactionIDs: [String]
    let sourceTransactionIDs: [String]
    let duplicateTransactionIDs: [String]
    let rows: [TransactionDuplicateReviewRow]
}

struct TransactionDuplicateReview: Hashable, Sendable, Identifiable {
    let id: String
    let context: TransactionSelectionContext
    let selections: [TransactionSelectionIdentity]
    let groups: [TransactionDuplicateGroupReview]
    let allocations: [TransactionDuplicateAllocation]
    let affectedResources: ChangedResources
    let reviewFingerprint: String
    let canSubmit: Bool
}

struct TransactionDuplicateReceipt: Hashable, Sendable {
    let changed: ChangedResources
    let actionID: String
}

struct TransactionDuplicateOutcome: Hashable, Sendable {
    let receipt: TransactionDuplicateReceipt
    let refreshPending: Bool
    let sessionCurrent: Bool
}
