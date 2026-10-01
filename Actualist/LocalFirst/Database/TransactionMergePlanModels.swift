import Foundation

/// Physical graph inputs belong to the database planning layer, not the
/// repository contract. Input IDs remain ordered and each graph is a complete
/// closure validated by `transactionBatchGraph` before planning.
struct TransactionMergePlannerInput: Equatable, Sendable {
    let orderedTransactionIDs: [String]
    let firstGraph: [TransactionBatchTransactionSnapshot]
    let secondGraph: [TransactionBatchTransactionSnapshot]
    let referenceMetadata: TransactionMergeReferenceMetadata
}

/// Complete pre-write snapshot data retained for a database-owned fingerprint.
struct TransactionMergeFingerprintInputs: Equatable, Sendable {
    let orderedTransactionIDs: [String]
    let firstGraph: [TransactionBatchTransactionSnapshot]
    let secondGraph: [TransactionBatchTransactionSnapshot]
    let referenceMetadata: TransactionMergeReferenceMetadata
}

/// Database-only write projection. Repository callers receive display rows and
/// a fingerprint string instead of physical before/after snapshots.
struct TransactionMergePlan: Equatable, Sendable {
    let orderedTransactionIDs: [String]
    let keptTransactionID: String
    let droppedTransactionID: String
    let fieldEffects: [TransactionMergeFieldEffect]
    let childMovements: [TransactionMergeChildMovement]
    let transferDisposition: TransactionMergeTransferDisposition
    let reciprocalTransferPairs: [TransactionMergeTransferPair]
    let beforeSnapshots: [TransactionBatchTransactionSnapshot]
    let afterSnapshots: [TransactionBatchTransactionSnapshot]
    let tombstonedTransactionIDs: [String]
    let tombstonedPeerIDs: [String]
    let reconciledTransactionIDs: [String]
    let affectedResources: TransactionMergeAffectedResources
    let fingerprintInputs: TransactionMergeFingerprintInputs
}

enum TransactionMergePlanningResult: Equatable, Sendable {
    case ready(TransactionMergePlan)
    case blocked(TransactionMergeBlockedReason)

    var plan: TransactionMergePlan? {
        guard case .ready(let plan) = self else { return nil }
        return plan
    }

    var blockedReason: TransactionMergeBlockedReason? {
        guard case .blocked(let reason) = self else { return nil }
        return reason
    }
}

/// `TransactionBatchTransactionSnapshot` is immutable, so the merge planner
/// builds proposed after-state rows through these explicit copy helpers rather
/// than mutating shared ActionLog snapshots. Every field is passed through
/// explicitly; `nil` always means a stored SQL NULL in the after-state.
extension TransactionBatchTransactionSnapshot {
    func mergingFields(
        payeeID: String?,
        categoryID: String?,
        notes: String?,
        cleared: Bool?,
        reconciled: Bool?,
        scheduleID: String?,
        isParent: Bool?,
        isChild: Bool?,
        parentID: String?,
        splitError: String?
    ) -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: id,
            columns: columns,
            accountID: accountID,
            dateValue: dateValue,
            amount: amount,
            payeeID: payeeID,
            categoryID: categoryID,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            tombstone: tombstone,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID,
            transferID: transferID,
            sortOrder: sortOrder,
            splitError: splitError,
            startingBalance: startingBalance,
            scheduleID: scheduleID,
            importedID: importedID,
            importedPayee: importedPayee,
            importedDescription: importedDescription
        )
    }

    func withTransferID(_ newTransferID: String?) -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: id,
            columns: columns,
            accountID: accountID,
            dateValue: dateValue,
            amount: amount,
            payeeID: payeeID,
            categoryID: categoryID,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            tombstone: tombstone,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID,
            transferID: newTransferID,
            sortOrder: sortOrder,
            splitError: splitError,
            startingBalance: startingBalance,
            scheduleID: scheduleID,
            importedID: importedID,
            importedPayee: importedPayee,
            importedDescription: importedDescription
        )
    }

    func reparented(to newParentID: String?) -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: id,
            columns: columns,
            accountID: accountID,
            dateValue: dateValue,
            amount: amount,
            payeeID: payeeID,
            categoryID: categoryID,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            tombstone: tombstone,
            isParent: isParent,
            isChild: isChild,
            parentID: newParentID,
            transferID: transferID,
            sortOrder: sortOrder,
            splitError: splitError,
            startingBalance: startingBalance,
            scheduleID: scheduleID,
            importedID: importedID,
            importedPayee: importedPayee,
            importedDescription: importedDescription
        )
    }

    func tombstoned() -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: id,
            columns: columns,
            accountID: accountID,
            dateValue: dateValue,
            amount: amount,
            payeeID: payeeID,
            categoryID: categoryID,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            tombstone: true,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID,
            transferID: transferID,
            sortOrder: sortOrder,
            splitError: splitError,
            startingBalance: startingBalance,
            scheduleID: scheduleID,
            importedID: importedID,
            importedPayee: importedPayee,
            importedDescription: importedDescription
        )
    }
}
