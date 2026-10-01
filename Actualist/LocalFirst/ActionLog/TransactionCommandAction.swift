import Foundation

/// Display facts for a duplicate command. IDs are retained so History can
/// describe every copied row, including split children and transfer peers.
struct TransactionDuplicateBudgetAction: Codable, Equatable, Sendable {
    var selectedSourceTransactionIDs: [String]
    var duplicateTransactionIDs: [String]
}

/// Display facts for a merge command. The ordered inputs preserve Actual's
/// second-input tie rule; affected IDs cover both complete transaction graphs.
struct TransactionMergeBudgetAction: Codable, Equatable, Sendable {
    var orderedInputTransactionIDs: [String]
    var keptTransactionID: String
    var droppedTransactionID: String
    var affectedGraphTransactionIDs: [String]
}

/// Input to the database's single local commit. Duplicate IDs are allocated by
/// the writer and retained through review/commit; this descriptor never allocates.
struct TransactionDuplicateActionDescriptor: Equatable, Sendable {
    let selectedSourceTransactionIDs: [String]
    let preallocatedCloneTransactionIDs: [String]
}

/// Merge's ordered inputs and whole-graph write set. `affectedGraphTransactionIDs`
/// is the sorted union of both complete graphs, not just the selected roots.
struct TransactionMergeActionDescriptor: Equatable, Sendable {
    let orderedInputTransactionIDs: [String]
    let keptTransactionID: String
    let droppedTransactionID: String
    let affectedGraphTransactionIDs: [String]
}

/// Duplicate undo only tombstones new rows, so it records the complete expected
/// post-duplicate state and deliberately has no source before-state.
struct TransactionDuplicateTransactionInverse: Codable, Equatable, Sendable {
    var afterSnapshots: [TransactionBatchTransactionSnapshot]
}

/// Merge undo restores the complete pre-merge graph only while every row and
/// relationship still matches this exact post-merge state.
struct TransactionMergeTransactionInverse: Codable, Equatable, Sendable {
    var beforeSnapshots: [TransactionBatchTransactionSnapshot]
    var afterSnapshots: [TransactionBatchTransactionSnapshot]
}

/// Short-lived source state used only while the forward duplicate action is
/// inside LocalCommit. It is not persisted in the History inverse.
enum TransactionCommandActionCapture: Sendable {
    case duplicateSources([TransactionBatchTransactionSnapshot])
}

/// Structural validation shared by database undo and the pure inverse evaluator.
/// Snapshot arrays use sorted, unique IDs so malformed or reordered records fail
/// closed before graph-membership helpers build ID-indexed dictionaries.
enum TransactionCommandActionValidation {
    static func duplicate(
        summary: TransactionDuplicateBudgetAction,
        inverse: TransactionDuplicateTransactionInverse
    ) -> Bool {
        let sourceIDs = summary.selectedSourceTransactionIDs
        let cloneIDs = summary.duplicateTransactionIDs
        return hasUniqueNonemptyIDs(sourceIDs)
            && hasCanonicalIDs(cloneIDs)
            && Set(sourceIDs).isDisjoint(with: Set(cloneIDs))
            && hasCanonicalSnapshots(inverse.afterSnapshots, ids: cloneIDs)
            && inverse.afterSnapshots.allSatisfy { $0.tombstone == false }
    }

    static func merge(
        summary: TransactionMergeBudgetAction,
        inverse: TransactionMergeTransactionInverse
    ) -> Bool {
        let inputs = summary.orderedInputTransactionIDs
        let affectedIDs = summary.affectedGraphTransactionIDs
        return inputs.count == 2
            && hasUniqueNonemptyIDs(inputs)
            && summary.keptTransactionID != summary.droppedTransactionID
            && Set(inputs) == Set([summary.keptTransactionID, summary.droppedTransactionID])
            && hasCanonicalIDs(affectedIDs)
            && Set(inputs).isSubset(of: Set(affectedIDs))
            && hasCanonicalSnapshots(inverse.beforeSnapshots, ids: affectedIDs)
            && hasCanonicalSnapshots(inverse.afterSnapshots, ids: affectedIDs)
            && Array(zip(inverse.beforeSnapshots, inverse.afterSnapshots))
                .allSatisfy { $0.0.columns == $0.1.columns }
            && inverse.beforeSnapshots.allSatisfy { $0.tombstone == false }
            && inverse.afterSnapshots.first(where: { $0.id == summary.keptTransactionID })?.tombstone == false
            && inverse.afterSnapshots.first(where: { $0.id == summary.droppedTransactionID })?.tombstone == true
    }

    static func hasCanonicalSnapshots(
        _ snapshots: [TransactionBatchTransactionSnapshot],
        ids: [String]
    ) -> Bool {
        hasCanonicalIDs(ids)
            && snapshots.map(\.id) == ids
            && snapshots.allSatisfy(isCompleteSnapshot)
    }

    static func isCompleteSnapshot(_ snapshot: TransactionBatchTransactionSnapshot) -> Bool {
        let columns = snapshot.columns
        let columnSet = Set(columns)
        let hasParentFlag = columnSet.contains("isParent") || columnSet.contains("is_parent")
        let hasChildFlag = columnSet.contains("isChild") || columnSet.contains("is_child")
        let hasTransferColumn = columnSet.contains("transferred_id") || columnSet.contains("transfer_id")
        let hasAccountColumn = columnSet.contains("acct") || columnSet.contains("account")
        let hasPayeeColumn = columnSet.contains("description") || columnSet.contains("payee")
        return !snapshot.id.isEmpty
            && columns == columns.sorted()
            && columnSet.count == columns.count
            && hasAccountColumn
            && hasPayeeColumn
            && columnSet.contains("date")
            && columnSet.contains("amount")
            && columnSet.contains("category")
            && columnSet.contains("tombstone")
            && columnSet.contains("parent_id")
            && hasParentFlag
            && hasChildFlag
            && hasTransferColumn
            && columnSet.contains("error")
            && snapshot.accountID?.isEmpty == false
            && snapshot.dateValue != nil
            && snapshot.amount != nil
            && snapshot.tombstone != nil
            && snapshot.isParent != nil
            && snapshot.isChild != nil
    }

    private static func hasUniqueNonemptyIDs(_ ids: [String]) -> Bool {
        !ids.isEmpty && ids.allSatisfy { !$0.isEmpty } && Set(ids).count == ids.count
    }

    private static func hasCanonicalIDs(_ ids: [String]) -> Bool {
        hasUniqueNonemptyIDs(ids) && ids == ids.sorted()
    }
}
