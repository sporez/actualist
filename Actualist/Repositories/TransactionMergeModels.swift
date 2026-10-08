import Foundation

/// Reference data needed to validate transfer endpoints without letting a
/// planner consult SQLite or a network client.
struct TransactionMergeAccountMetadata: Hashable, Sendable {
    let id: String
    let isOffBudget: Bool
}

struct TransactionMergePayeeDestination: Hashable, Sendable {
    let payeeID: String
    let accountID: String
}

struct TransactionMergeReferenceMetadata: Hashable, Sendable {
    let accounts: [TransactionMergeAccountMetadata]
    let transferPayeeDestinations: [TransactionMergePayeeDestination]
}

enum TransactionMergeBlockedReason: Hashable, Sendable {
    case requiresExactlyTwoIDs
    case emptyTransactionID
    case duplicateTransactionID
    case missingRootSnapshot(String)
    case selectedChild(String)
    case overlappingGraphs([String])
    case malformedRow(String)
    case missingAccountMetadata(String)
    case invalidReferenceMetadata
    case zeroChildSplit(String)
    case splitHasError(String)
    case malformedSplit(String)
    case malformedTransfer(String)
    case extraIncomingTransfer(String)
    case missingTransferDestination(String)
    case accountMismatch
    case amountMismatch
    case differentTransferDestinations
    case invalidProposedParentFields(String)
}

enum TransactionMergeField: String, Hashable, Sendable {
    case accountID
    case dateValue
    case amount
    case payeeID
    case categoryID
    case notes
    case cleared
    case reconciled
    case scheduleID
    case importedID
    case importedPayee
    case importedDescription
    case startingBalance
    case sortOrder
}

enum TransactionMergeFieldValue: Hashable, Sendable {
    case text(String?)
    case integer(Int?)
    case boolean(Bool?)
    case decimal(Double?)
}

enum TransactionMergeFieldWinner: Hashable, Sendable {
    case keptIdentity
    case keptValue
    case droppedFallback
    case logicalOr
    case splitParentConstraint
    case transferDestination
}

struct TransactionMergeFieldEffect: Hashable, Sendable {
    let transactionID: String
    let field: TransactionMergeField
    let beforeValue: TransactionMergeFieldValue
    let droppedValue: TransactionMergeFieldValue
    let afterValue: TransactionMergeFieldValue
    let winner: TransactionMergeFieldWinner
}

struct TransactionMergeChildMovement: Hashable, Sendable {
    let childID: String
    let originalParentID: String
    let newParentID: String
}

enum TransactionMergeTransferDisposition: Hashable, Sendable {
    case none
    case adoptedPair(peerID: String, destinationAccountID: String)
    case mergedPairs(
        keptPeerID: String,
        droppedPeerID: String,
        destinationAccountID: String
    )
}

struct TransactionMergeTransferPair: Hashable, Sendable {
    let firstTransactionID: String
    let secondTransactionID: String

    init(_ firstID: String, _ secondID: String) {
        if firstID < secondID {
            firstTransactionID = firstID
            secondTransactionID = secondID
        } else {
            firstTransactionID = secondID
            secondTransactionID = firstID
        }
    }
}

struct TransactionMergeAffectedResources: Hashable, Sendable {
    let changed: ChangedResources
    let payeeIDs: [String]
    let categoryIDs: [String]
}

struct TransactionMergeReviewRow: Hashable, Sendable, Identifiable {
    let transactionID: String
    let accountID: String
    let date: String
    let amountMinorUnits: Int
    let payeeID: String?
    let categoryID: String?
    let notes: String?
    let cleared: Bool?
    let reconciled: Bool?
    let isParent: Bool
    let isChild: Bool
    let isTransfer: Bool
    /// Resolved payee (or transfer counterpart account) name; nil when none.
    var payeeName: String? = nil

    var id: String { transactionID }
}

struct TransactionMergeReview: Hashable, Sendable, Identifiable {
    let id: String
    let context: TransactionSelectionContext
    let orderedTransactionIDs: [String]
    let keptRow: TransactionMergeReviewRow?
    let droppedRow: TransactionMergeReviewRow?
    let fieldEffects: [TransactionMergeFieldEffect]
    let childMovements: [TransactionMergeChildMovement]
    let transferDisposition: TransactionMergeTransferDisposition
    let reciprocalTransferPairs: [TransactionMergeTransferPair]
    let tombstonedTransactionIDs: [String]
    let tombstonedPeerIDs: [String]
    let affectedResources: TransactionMergeAffectedResources
    let blockedReason: TransactionMergeBlockedReason?
    let reconciledTransactionIDs: [String]
    let reviewFingerprint: String
    /// The two selected rows as they are now, so a blocked review can still
    /// show them. Empty when the review was built without row data.
    var inputRows: [TransactionMergeReviewRow] = []

    var canSubmit: Bool {
        blockedReason == nil && keptRow != nil && droppedRow != nil
    }
}

struct TransactionMergeAuthorization: Hashable, Sendable {
    let reviewID: String
    let reviewFingerprint: String
    let reconciledTransactionIDs: [String]
}

struct TransactionMergeReceipt: Hashable, Sendable {
    let changedAccountIDs: [String]
    let changedMonths: [String]
    let changedTransactionIDs: [String]
    let actionID: String
}

struct TransactionMergeOutcome: Hashable, Sendable {
    let receipt: TransactionMergeReceipt
    let refreshPending: Bool
    let sessionCurrent: Bool
}
