import Foundation
import GRDB

/// Command-specific ActionLog capture, finalization, conflict checks, and undo
/// presentation. Existing transaction graph snapshot/message helpers remain the
/// single representation and implementation of row membership/restore.
enum TransactionCommandActionLogSQL {
    static func captureTransactionDuplicateActionLogFacts(
        _ duplicate: TransactionDuplicateActionDescriptor,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ActionLogSQL.ActionLogFacts {
        let sourceSnapshots = try transactionCommandSourceSnapshots(
            selectedSourceIDs: duplicate.selectedSourceTransactionIDs,
            in: database,
            db: db
        )
        let cloneIDs = duplicate.preallocatedCloneTransactionIDs.sorted()
        guard !cloneIDs.isEmpty,
              cloneIDs.allSatisfy({ !$0.isEmpty }),
              Set(cloneIDs).count == cloneIDs.count,
              Set(cloneIDs).isDisjoint(with: Set(sourceSnapshots.map(\.id))) else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction duplicate descriptor")
        }
        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        for id in cloneIDs {
            guard try database.transactionBatchSnapshot(id: id, columns: columns, db: db) == nil else {
                throw LocalFirstError.invalidLocalWrite("a transaction duplicate ID already exists")
            }
        }
        let summary = TransactionDuplicateBudgetAction(
            selectedSourceTransactionIDs: duplicate.selectedSourceTransactionIDs,
            duplicateTransactionIDs: cloneIDs
        )
        return ActionLogSQL.ActionLogFacts(
            kind: .transactionDuplicate,
            month: "",
            summary: .transactionDuplicate(summary),
            inverse: .transactionDuplicate(TransactionDuplicateTransactionInverse(afterSnapshots: [])),
            affectedCategoryIDs: Array(Set(sourceSnapshots.compactMap(\.categoryID))).sorted(),
            transactionCommandCapture: .duplicateSources(sourceSnapshots)
        )
    }

    static func captureTransactionMergeActionLogFacts(
        _ merge: TransactionMergeActionDescriptor,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ActionLogSQL.ActionLogFacts {
        let before = try transactionMergeBeforeSnapshots(merge, in: database, db: db)
        let summary = TransactionMergeBudgetAction(
            orderedInputTransactionIDs: merge.orderedInputTransactionIDs,
            keptTransactionID: merge.keptTransactionID,
            droppedTransactionID: merge.droppedTransactionID,
            affectedGraphTransactionIDs: merge.affectedGraphTransactionIDs
        )
        return ActionLogSQL.ActionLogFacts(
            kind: .transactionMerge,
            month: "",
            summary: .transactionMerge(summary),
            inverse: .transactionMerge(TransactionMergeTransactionInverse(
                beforeSnapshots: before,
                afterSnapshots: []
            )),
            affectedCategoryIDs: Array(Set(before.compactMap(\.categoryID))).sorted()
        )
    }

    static func completeTransactionCommandActionLogFacts(
        _ facts: ActionLogSQL.ActionLogFacts,
        descriptor: BudgetActionDescriptor,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ActionLogSQL.ActionLogFacts {
        switch descriptor {
        case .transactionDuplicate(let duplicate):
            guard case .transactionDuplicate(var inverse) = facts.inverse,
                  case .transactionDuplicate(let summary) = facts.summary,
                  case .duplicateSources(let sourceBefore)? = facts.transactionCommandCapture else {
                throw LocalFirstError.invalidLocalWrite("transaction duplicate History facts are incomplete")
            }
            try validateTransactionCommandSourceUnchanged(sourceBefore, in: database, db: db)
            let cloneIDs = duplicate.preallocatedCloneTransactionIDs.sorted()
            let after = try completeTransactionCommandSnapshots(ids: cloneIDs, in: database, db: db)
            let completeCloneGraph = try transactionCommandSourceSnapshots(
                selectedSourceIDs: cloneIDs,
                in: database,
                db: db
            )
            guard after.allSatisfy({ $0.tombstone == false }),
                  completeCloneGraph.map(\.id) == cloneIDs,
                  Array(zip(after, completeCloneGraph)).allSatisfy({ $0.0.matches($0.1) }),
                  try database.transactionBatchGraphMembershipMatches(after, db: db) else {
                throw LocalFirstError.invalidLocalWrite("transaction duplicate graph changed while recording History")
            }
            inverse.afterSnapshots = after
            let completedSummary = TransactionDuplicateBudgetAction(
                selectedSourceTransactionIDs: summary.selectedSourceTransactionIDs,
                duplicateTransactionIDs: cloneIDs
            )
            var completed = facts
            completed.summary = .transactionDuplicate(completedSummary)
            completed.inverse = .transactionDuplicate(inverse)
            return completed

        case .transactionMerge(let merge):
            guard case .transactionMerge(var inverse) = facts.inverse,
                  case .transactionMerge(let summary) = facts.summary else {
                throw LocalFirstError.invalidLocalWrite("transaction merge History facts are incomplete")
            }
            let after = try completeTransactionCommandSnapshots(
                ids: merge.affectedGraphTransactionIDs,
                in: database,
                db: db
            )
            guard try database.transactionBatchGraphMembershipMatches(after, db: db),
                  let kept = after.first(where: { $0.id == summary.keptTransactionID }),
                  let dropped = after.first(where: { $0.id == summary.droppedTransactionID }),
                  kept.tombstone == false,
                  dropped.tombstone == true else {
                throw LocalFirstError.invalidLocalWrite("transaction merge graph changed while recording History")
            }
            inverse.afterSnapshots = after
            var completed = facts
            completed.inverse = .transactionMerge(inverse)
            return completed

        default:
            throw LocalFirstError.invalidLocalWrite("unexpected action in transaction command finalization")
        }
    }

    static func transactionCommandUndoMessages(
        plan: BudgetActionUndoPlan,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        switch plan {
        case .tombstoneDuplicateTransactions(let transactionIDs):
            return try transactionIDs.map { id in
                try builder.tombstone(dataset: "transactions", row: id)
            }
        case .restoreMergedTransactions(let snapshots):
            let columns = try TransactionRowColumns.resolve(in: database, db: db)
            var messages: [ActualSyncDecodedMessage] = []
            for snapshot in snapshots {
                messages += try database.transactionBatchRestoreMessages(
                    snapshot,
                    columns: columns,
                    builder: &builder
                )
            }
            return messages
        case .assignments, .tombstoneTransactions, .unTombstoneTransactions,
                .restoreSnapshots, .restoreCategories, .restoreBatchTransactions:
            throw LocalFirstError.invalidLocalWrite("unexpected plan in transaction command undo")
        }
    }

    static func transactionDuplicateUndoStateMatches(
        _ expected: [TransactionBatchTransactionSnapshot],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Bool {
        do {
            let current = try transactionCommandSourceSnapshots(
                selectedSourceIDs: expected.map(\.id),
                in: database,
                db: db
            )
            return current.map(\.id) == expected.map(\.id)
                && Array(zip(current, expected)).allSatisfy({ $0.0.matches($0.1) })
        } catch is LocalFirstError {
            return false
        }
    }

    static func transactionCommandUndoPreviewLines(
        record: BudgetActionRecord,
        plan: BudgetActionUndoPlan
    ) -> [BudgetActionUndoPreview.TransactionLine] {
        switch record.summary {
        case .transactionDuplicate:
            guard case .tombstoneDuplicateTransactions(let ids) = plan else { return [] }
            guard case .transactionDuplicate(let inverse) = record.inverse else { return [] }
            let snapshots = Dictionary(uniqueKeysWithValues: inverse.afterSnapshots.map { ($0.id, $0) })
            return ids.compactMap { id in
                guard let snapshot = snapshots[id] else { return nil }
                return BudgetActionUndoPreview.TransactionLine(
                    id: id,
                    payeeName: nil,
                    amount: snapshot.amount,
                    currentCategoryID: snapshot.categoryID,
                    proposedCategoryID: nil,
                    effect: .duplicateRemoval,
                    isLinkedEntry: snapshot.parentID != nil || snapshot.transferID != nil
                )
            }

        case .transactionMerge(let merge):
            guard case .restoreMergedTransactions(let beforeSnapshots) = plan else { return [] }
            guard case .transactionMerge(let inverse) = record.inverse else { return [] }
            let afterByID = Dictionary(uniqueKeysWithValues: inverse.afterSnapshots.map { ($0.id, $0) })
            let beforeByID = Dictionary(uniqueKeysWithValues: beforeSnapshots.map { ($0.id, $0) })
            return merge.affectedGraphTransactionIDs.compactMap { id in
                guard let before = beforeByID[id], let after = afterByID[id] else { return nil }
                return BudgetActionUndoPreview.TransactionLine(
                    id: id,
                    payeeName: nil,
                    amount: after.amount,
                    currentCategoryID: after.categoryID,
                    proposedCategoryID: before.categoryID,
                    effect: .mergeRestoration,
                    proposedAmount: before.amount,
                    isLinkedEntry: !merge.orderedInputTransactionIDs.contains(id)
                )
            }

        case .assign, .move, .template, .createTransaction, .editTransaction,
                .deleteTransaction, .categorize, .transactionBatch,
                .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            return []
        }
    }

    private static func transactionCommandSourceSnapshots(
        selectedSourceIDs: [String],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [TransactionBatchTransactionSnapshot] {
        guard !selectedSourceIDs.isEmpty,
              selectedSourceIDs.allSatisfy({ !$0.isEmpty }),
              Set(selectedSourceIDs).count == selectedSourceIDs.count else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction duplicate source IDs")
        }
        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        try requireTransactionCommandGraphSchema(columns)
        var snapshotsByID: [String: TransactionBatchTransactionSnapshot] = [:]
        for sourceID in selectedSourceIDs {
            let graph = try database.transactionBatchGraph(containing: sourceID, columns: columns, db: db)
            guard graph.invalidReason == nil,
                  graph.snapshots[sourceID] != nil,
                  graph.snapshots.values.allSatisfy({
                      $0.tombstone == false && !SplitTransactionError.isPresent($0.splitError)
                  }) else {
                throw LocalFirstError.invalidLocalWrite("a transaction duplicate source graph is incomplete")
            }
            for snapshot in graph.snapshots.values {
                guard TransactionCommandActionValidation.isCompleteSnapshot(snapshot) else {
                    throw LocalFirstError.invalidLocalWrite("a transaction duplicate source graph is incomplete")
                }
                if let existing = snapshotsByID[snapshot.id], !existing.matches(snapshot) {
                    throw LocalFirstError.invalidLocalWrite("overlapping transaction duplicate sources changed")
                }
                snapshotsByID[snapshot.id] = snapshot
            }
        }
        let snapshots = snapshotsByID.values.sorted { $0.id < $1.id }
        guard try database.transactionBatchGraphMembershipMatches(snapshots, db: db) else {
            throw LocalFirstError.invalidLocalWrite("a transaction duplicate source graph is incomplete")
        }
        return snapshots
    }

    private static func transactionMergeBeforeSnapshots(
        _ descriptor: TransactionMergeActionDescriptor,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [TransactionBatchTransactionSnapshot] {
        let inputs = descriptor.orderedInputTransactionIDs
        let affectedIDs = descriptor.affectedGraphTransactionIDs
        guard inputs.count == 2,
              inputs.allSatisfy({ !$0.isEmpty }),
              Set(inputs).count == 2,
              descriptor.keptTransactionID != descriptor.droppedTransactionID,
              Set(inputs) == Set([descriptor.keptTransactionID, descriptor.droppedTransactionID]),
              !affectedIDs.isEmpty,
              affectedIDs.allSatisfy({ !$0.isEmpty }),
              affectedIDs == affectedIDs.sorted(),
              Set(affectedIDs).count == affectedIDs.count,
              Set(inputs).isSubset(of: Set(affectedIDs)) else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction merge descriptor")
        }
        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        try requireTransactionCommandGraphSchema(columns)
        var snapshotsByID: [String: TransactionBatchTransactionSnapshot] = [:]
        var graphIDs = Set<String>()
        for inputID in inputs {
            let graph = try database.transactionBatchGraph(containing: inputID, columns: columns, db: db)
            guard graph.invalidReason == nil,
                  let input = graph.snapshots[inputID],
                  input.isChild == false,
                  input.parentID == nil,
                  graph.snapshots.values.allSatisfy({
                      $0.tombstone == false && !SplitTransactionError.isPresent($0.splitError)
                  }),
                  graphIDs.isDisjoint(with: Set(graph.snapshots.keys)) else {
                throw LocalFirstError.invalidLocalWrite("a transaction merge source graph is incomplete")
            }
            graphIDs.formUnion(graph.snapshots.keys)
            for snapshot in graph.snapshots.values {
                guard TransactionCommandActionValidation.isCompleteSnapshot(snapshot) else {
                    throw LocalFirstError.invalidLocalWrite("a transaction merge source graph is incomplete")
                }
                snapshotsByID[snapshot.id] = snapshot
            }
        }
        guard graphIDs.sorted() == affectedIDs else {
            throw LocalFirstError.invalidLocalWrite("transaction merge graph IDs changed")
        }
        let snapshots = snapshotsByID.values.sorted { $0.id < $1.id }
        guard snapshots.map(\.id) == affectedIDs,
              try database.transactionBatchGraphMembershipMatches(snapshots, db: db) else {
            throw LocalFirstError.invalidLocalWrite("a transaction merge source graph is incomplete")
        }
        return snapshots
    }

    private static func validateTransactionCommandSourceUnchanged(
        _ before: [TransactionBatchTransactionSnapshot],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let ids = before.map(\.id)
        let current = try completeTransactionCommandSnapshots(ids: ids, in: database, db: db)
        guard Array(zip(before, current)).allSatisfy({ $0.0.matches($0.1) }),
              try database.transactionBatchGraphMembershipMatches(before, db: db) else {
            throw LocalFirstError.invalidLocalWrite("a transaction duplicate source changed while recording History")
        }
    }

    private static func completeTransactionCommandSnapshots(
        ids: [String],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [TransactionBatchTransactionSnapshot] {
        guard !ids.isEmpty,
              ids.allSatisfy({ !$0.isEmpty }),
              ids == ids.sorted(),
              Set(ids).count == ids.count else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction command snapshot IDs")
        }
        let snapshots = try database.transactionBatchSnapshots(ids: ids, db: db)
        guard snapshots.map(\.id) == ids,
              snapshots.allSatisfy(TransactionCommandActionValidation.isCompleteSnapshot) else {
            throw LocalFirstError.invalidLocalWrite("a transaction command snapshot is incomplete")
        }
        return snapshots
    }

    private static func requireTransactionCommandGraphSchema(
        _ columns: TransactionRowColumns
    ) throws {
        guard columns.hasTombstone,
              columns.hasParentID,
              columns.isParent != nil,
              columns.isChild != nil,
              columns.transferID != nil,
              columns.hasError else {
            throw LocalFirstError.invalidLocalWrite("the transaction graph schema is incomplete")
        }
    }
}
