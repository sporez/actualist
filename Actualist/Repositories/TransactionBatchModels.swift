import Foundation

struct TransactionSelectionIdentity: Hashable, Sendable, Identifiable {
    enum Role: Hashable, Sendable {
        case root
        case child
    }

    let transactionID: String
    let familyRootID: String
    let role: Role

    var id: String { transactionID }

    init?(transactionID: String?, familyRootID: String?, role: Role) {
        guard let transactionID, !transactionID.isEmpty,
              let familyRootID, !familyRootID.isEmpty else { return nil }
        guard (role == .root && familyRootID == transactionID)
                || (role == .child && familyRootID != transactionID) else { return nil }
        self.transactionID = transactionID
        self.familyRootID = familyRootID
        self.role = role
    }

    init?(transaction: ActualTransaction) {
        guard let transactionID = transaction.id, !transactionID.isEmpty else { return nil }
        let role: Role = transaction.isChild ? .child : .root
        let familyRootID = transaction.isChild ? transaction.parentID : transactionID
        self.init(transactionID: transactionID, familyRootID: familyRootID, role: role)
    }
}

struct TransactionSelectionContext: Hashable, Sendable {
    let budgetID: String
    let sessionGeneration: Int
    let scope: TransactionQueryScope
    let querySignature: TransactionQuerySignature
}

enum TransactionBatchIntent: Hashable, Sendable {
    case clear
    case categorize(categoryID: String?)
    case delete
}

enum TransactionBatchDisposition: Hashable, Sendable, Identifiable {
    case eligible(TransactionBatchEffectSummary)
    case skipped(TransactionBatchDispositionReason)
    case requiresAuthorization(TransactionBatchAuthorizationRequirement)
    case blocked(TransactionBatchDispositionReason)

    var id: String {
        switch self {
        case .eligible(let summary): summary.selection.transactionID
        case .skipped(let reason): reason.selection.transactionID
        case .requiresAuthorization(let requirement): requirement.selection.transactionID
        case .blocked(let reason): reason.selection.transactionID
        }
    }

    var selection: TransactionSelectionIdentity {
        switch self {
        case .eligible(let summary): summary.selection
        case .skipped(let reason): reason.selection
        case .requiresAuthorization(let requirement): requirement.selection
        case .blocked(let reason): reason.selection
        }
    }
}

struct TransactionBatchEffectSummary: Hashable, Sendable {
    let selection: TransactionSelectionIdentity
    let affectedTransactionIDs: [String]
    let description: String

    var affectedTransactionCount: Int { Set(affectedTransactionIDs).count }
}

struct TransactionBatchDispositionReason: Hashable, Sendable {
    let selection: TransactionSelectionIdentity
    let explanation: String
}

struct TransactionBatchAuthorizationRequirement: Hashable, Sendable {
    let effect: TransactionBatchEffectSummary
    let reconciledTransactionIDs: [String]
    let pairedReconciledTransactionIDs: [String]

    var selection: TransactionSelectionIdentity { effect.selection }
    var reconciledTargetCount: Int { Set(reconciledTransactionIDs).count }
    var reconciledPairCount: Int { Set(pairedReconciledTransactionIDs).count }
}

struct TransactionBatchAuthorization: Hashable, Sendable {
    let reviewID: String
    let reviewFingerprint: String
    let reconciledTransactionIDs: [String]
    let pairedReconciledTransactionIDs: [String]
}

struct TransactionBatchRowSnapshot: Codable, Hashable, Sendable {
    let id: String
    let accountID: String?
    let dateValue: Int?
    let amount: Int?
    let payeeID: String?
    let categoryID: String?
    let notes: String?
    let cleared: Bool?
    let reconciled: Bool?
    let tombstone: Bool?
    let isParent: Bool?
    let isChild: Bool?
    let parentID: String?
    let transferID: String?
    let sortOrder: Double?
    let startingBalance: Bool?
    let splitError: SplitTransactionError?
    let scheduleID: String?
    let importedID: String?
    let importedPayee: String?
}

struct TransactionBatchReviewMetadata: Hashable, Sendable {
    let currency: BudgetCurrency
    let accountNames: [String: String]
    let payeeNames: [String: String]
    let categoryNames: [String: String]
}

struct TransactionBatchRowChange: Hashable, Sendable {
    let before: TransactionBatchRowSnapshot
    let after: TransactionBatchRowSnapshot

    var id: String { before.id }
    var changed: Bool { before != after }
}

enum TransactionBatchClearTarget {
    /// Actual v26.9.0's batch action sets cleared to true when any row in the
    /// loaded, ungrouped transaction set is uncleared; otherwise it sets false.
    /// The caller supplies that source-ordered set, including loaded family
    /// context. Missing cleared state is not guessed.
    static func fromLoadedRows(_ rows: [TransactionBatchRowSnapshot]) -> Bool? {
        guard !rows.isEmpty, rows.allSatisfy({ $0.cleared != nil }) else { return nil }
        return rows.contains { $0.cleared == false }
    }
}

struct TransactionBatchReview: Hashable, Sendable, Identifiable {
    let id: String
    let context: TransactionSelectionContext
    let intent: TransactionBatchIntent
    let selections: [TransactionSelectionIdentity]
    /// IDs in the currently loaded, ungrouped feed used by Actual's clear
    /// target calculation. The write boundary rereads these rows atomically.
    let loadedUngroupedTransactionIDs: [String]
    let dispositions: [TransactionBatchDisposition]
    /// One authoritative before/after projection of every row pinned by this
    /// review. Unchanged loaded rows remain available for clear-target review.
    let rowChanges: [TransactionBatchRowChange]
    let metadata: TransactionBatchReviewMetadata
    let clearTarget: Bool?
    let reviewFingerprint: String
    let effectsDescription: String
    let authorization: TransactionBatchAuthorization?
    let canSubmit: Bool

    var rowSnapshots: [TransactionBatchRowSnapshot] { rowChanges.map(\.before) }

    var eligibleCount: Int {
        dispositions.reduce(into: 0) { count, disposition in
            if case .eligible = disposition { count += 1 }
        }
    }

    var actionableCount: Int {
        dispositions.reduce(into: 0) { count, disposition in
            switch disposition {
            case .eligible, .requiresAuthorization:
                count += 1
            case .skipped, .blocked:
                break
            }
        }
    }

    var skippedCount: Int {
        Set(skippedSelectionIDs).count
    }

    var skippedSelectionIDs: [String] {
        dispositions.compactMap { disposition in
            guard case .skipped = disposition else { return nil }
            return disposition.selection.transactionID
        }
    }

    var blockedCount: Int {
        dispositions.reduce(into: 0) { count, disposition in
            if case .blocked = disposition { count += 1 }
        }
    }
}

struct TransactionBatchResult: Hashable, Sendable {
    let changedAccountIDs: [String]
    let changedMonthIDs: [String]
    let changedTransactionIDs: [String]
    let actionID: String
}

/// The database receipt is durable once returned, even if its session is
/// retired or observable caches cannot be refreshed afterward.
struct TransactionBatchOutcome: Hashable, Sendable {
    let receipt: TransactionBatchResult
    let refreshPending: Bool
    let sessionCurrent: Bool
}
