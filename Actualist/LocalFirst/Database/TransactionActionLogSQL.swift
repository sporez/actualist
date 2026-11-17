import Foundation
import GRDB

enum TransactionActionLogSQL {
    static func captureTransactionActionLogFacts(
        descriptor: BudgetActionDescriptor,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ActionLogSQL.ActionLogFacts {
        switch descriptor {
        case .createTransaction(let create):
            let summary = TransactionBudgetAction(
                month: create.month,
                amount: create.amount,
                payeeName: create.payeeName,
                categoryID: create.categoryID,
                graph: create.graph.kind,
                transactionCount: create.transactionIDs.count
            )
            return ActionLogSQL.ActionLogFacts(
                kind: .createTransaction,
                month: create.month,
                summary: .createTransaction(summary),
                inverse: .createTransaction(CreateTransactionInverse(
                    month: create.month,
                    primaryTransactionID: create.primaryTransactionID,
                    transactionIDs: create.transactionIDs,
                    graph: create.graph,
                    createdPayeeID: create.createdPayeeID,
                    learning: .empty
                )),
                affectedCategoryIDs: [create.categoryID].compactMap { $0 }
            )

        case .deleteTransaction(let delete):
            let summary = TransactionBudgetAction(
                month: delete.month,
                amount: delete.amount,
                payeeName: delete.payeeName,
                categoryID: delete.categoryID,
                graph: delete.graph.kind,
                transactionCount: delete.transactionIDs.count
            )
            return ActionLogSQL.ActionLogFacts(
                kind: .deleteTransaction,
                month: delete.month,
                summary: .deleteTransaction(summary),
                inverse: .deleteTransaction(DeleteTransactionInverse(
                    month: delete.month,
                    transactionIDs: delete.transactionIDs,
                    graph: delete.graph
                )),
                affectedCategoryIDs: [delete.categoryID].compactMap { $0 }
            )

        case .editTransaction(let edit):
            guard let primaryBefore = try transactionUndoSnapshot(id: edit.transactionID, in: database, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing transaction")
            }
            var relatedBefore: [TransactionUndoSnapshot] = []
            for relatedID in edit.affectedIDs where relatedID != edit.transactionID {
                if let snapshot = try transactionUndoSnapshot(id: relatedID, in: database, db: db) {
                    relatedBefore.append(snapshot)
                }
            }
            let summary = EditTransactionBudgetAction(
                month: edit.month,
                amountBefore: primaryBefore.amount,
                amountAfter: primaryBefore.amount,
                payeeName: edit.payeeName,
                graph: graphKind(from: primaryBefore),
                unsafeGraph: edit.unsafeGraph
            )
            return ActionLogSQL.ActionLogFacts(
                kind: .editTransaction,
                month: edit.month,
                summary: .editTransaction(summary),
                inverse: .editTransaction(EditTransactionInverse(
                    month: edit.month,
                    primaryBefore: primaryBefore,
                    primaryAfter: primaryBefore,
                    relatedBefore: relatedBefore,
                    relatedAfter: [],
                    unsafeGraph: edit.unsafeGraph,
                    createdPayeeID: edit.createdPayeeID,
                    learning: .empty
                )),
                affectedCategoryIDs: [primaryBefore.categoryID].compactMap { $0 }
            )

        case .categorize(let categorize):
            return ActionLogSQL.ActionLogFacts(
                kind: .categorize,
                month: categorize.month,
                summary: .categorize(CategorizeBudgetAction(
                    month: categorize.month,
                    categoryID: categorize.categoryID,
                    itemCount: categorize.items.count
                )),
                inverse: .categorize(CategorizeTransactionInverse(
                    month: categorize.month,
                    items: categorize.items,
                    learning: .empty
                )),
                affectedCategoryIDs: Array(Set(
                    [categorize.categoryID] + categorize.items.compactMap(\.beforeCategoryID)
                )).sorted()
            )

        case .transactionBatch(let batch):
            let before = try TransactionBatchSnapshotSQL.transactionBatchSnapshots(ids: batch.snapshotTransactionIDs, in: database, db: db)
            guard before.count == Set(batch.snapshotTransactionIDs).count else {
                throw LocalFirstError.invalidLocalWrite("a transaction in the batch changed before action logging")
            }
            let summary = TransactionBatchBudgetAction(
                operation: batch.operation,
                selectedCount: batch.selectedTransactionIDs.count,
                changedCount: Set(batch.affectedTransactionIDs).count,
                clearTarget: batch.clearTarget,
                categoryID: batch.categoryID
            )
            return ActionLogSQL.ActionLogFacts(
                kind: .transactionBatch,
                month: "",
                summary: .transactionBatch(summary),
                inverse: .transactionBatch(TransactionBatchTransactionInverse(
                    operation: batch.operation,
                    selectedTransactionIDs: batch.selectedTransactionIDs,
                    beforeSnapshots: before,
                    afterSnapshots: before,
                    learning: .empty
                )),
                affectedCategoryIDs: Array(Set(
                    before.compactMap(\.categoryID) + [batch.categoryID].compactMap { $0 }
                )).sorted()
            )

        case .transactionDuplicate(let duplicate):
            return try TransactionCommandActionLogSQL.captureTransactionDuplicateActionLogFacts(duplicate, in: database, db: db)

        case .transactionMerge(let merge):
            return try TransactionCommandActionLogSQL.captureTransactionMergeActionLogFacts(merge, in: database, db: db)

        case .assign, .move, .template, .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            throw LocalFirstError.invalidLocalWrite("unexpected budget action in transaction capture")
        }
    }

    static func completeActionLogFacts(
        _ facts: ActionLogSQL.ActionLogFacts,
        descriptor: BudgetActionDescriptor,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> ActionLogSQL.ActionLogFacts {
        switch descriptor {
        case .transactionDuplicate, .transactionMerge:
            return try TransactionCommandActionLogSQL.completeTransactionCommandActionLogFacts(
                facts,
                descriptor: descriptor,
                in: database,
                db: db
            )
        case .assign, .move, .template, .createTransaction, .editTransaction,
                .deleteTransaction, .categorize, .transactionBatch,
                .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            break
        }
        if case .transactionBatch(let batch) = descriptor,
           case .transactionBatch(var inverse) = facts.inverse {
            let after = try TransactionBatchSnapshotSQL.transactionBatchSnapshots(ids: batch.snapshotTransactionIDs, in: database, db: db)
            guard after.count == Set(batch.snapshotTransactionIDs).count else {
                throw LocalFirstError.invalidLocalWrite("a transaction disappeared while recording the batch")
            }
            inverse.afterSnapshots = after
            var completed = facts
            completed.inverse = .transactionBatch(inverse)
            return completed
        }
        guard case .editTransaction(let edit) = descriptor,
              case .editTransaction(var inverse) = facts.inverse else { return facts }
        guard let primaryAfter = try transactionUndoSnapshot(id: edit.transactionID, in: database, db: db) else {
            return facts
        }
        var relatedAfter: [TransactionUndoSnapshot] = []
        for relatedID in edit.affectedIDs where relatedID != edit.transactionID {
            if let snapshot = try transactionUndoSnapshot(id: relatedID, in: database, db: db) {
                relatedAfter.append(snapshot)
            }
        }
        inverse.primaryAfter = primaryAfter
        inverse.relatedAfter = relatedAfter
        var completed = facts
        completed.inverse = .editTransaction(inverse)
        completed.summary = .editTransaction(EditTransactionBudgetAction(
            month: edit.month,
            amountBefore: inverse.primaryBefore.amount,
            amountAfter: primaryAfter.amount,
            payeeName: edit.payeeName,
            graph: graphKind(from: primaryAfter),
            unsafeGraph: edit.unsafeGraph
        ))
        return completed
    }

    static func learningSideEffect(
        beforeRules: [ManagedRule],
        messages: [ActualSyncDecodedMessage]
    ) -> BudgetActionLearningSideEffect {
        let beforeByID = Dictionary(uniqueKeysWithValues: beforeRules.map { ($0.id, $0) })
        var created: [String] = []
        var updated: [BudgetActionLearningRuleUpdate] = []
        var seen = Set<String>()
        for message in messages where message.dataset == "rules" {
            let ruleID = message.row
            guard seen.insert(ruleID).inserted else { continue }
            if let existing = beforeByID[ruleID] {
                let afterActions = messages.last {
                    $0.dataset == "rules" && $0.row == ruleID && $0.column == "actions"
                }?.serializedValue
                let afterJSON = afterActions.flatMap(decodedSyncString) ?? existing.rawActionsJSON
                if afterJSON != existing.rawActionsJSON {
                    updated.append(BudgetActionLearningRuleUpdate(
                        ruleID: ruleID,
                        beforeActionsJSON: existing.rawActionsJSON,
                        afterActionsJSON: afterJSON
                    ))
                }
            } else {
                created.append(ruleID)
            }
        }
        return BudgetActionLearningSideEffect(
            createdRuleIDs: created.sorted(),
            updatedRules: updated.sorted { $0.ruleID < $1.ruleID }
        )
    }

    static func liveTransactionsForUndo(
        ids: [String],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: TransactionUndoSnapshot?] {
        var pending = ids
        var live: [String: TransactionUndoSnapshot?] = [:]
        var seen = Set<String>()
        while let id = pending.first {
            pending.removeFirst()
            guard seen.insert(id).inserted else { continue }
            let snapshot = try transactionUndoSnapshot(id: id, in: database, db: db)
            live[id] = snapshot
            if let snapshot, snapshot.isParent,
               try database.tableExists("transactions", db: db) {
                let columns = try TransactionRowColumns.resolve(in: database, db: db)
                if columns.hasParentID {
                    let children = try String.fetchAll(
                        db,
                        sql: "SELECT id FROM transactions WHERE parent_id = ?",
                        arguments: [id]
                    )
                    pending.append(contentsOf: children)
                }
            }
        }
        return live
    }

    /// The subset of `required` accounts and categories that exist and are not
    /// tombstoned. A closed account is still live: upstream keeps transactions in it.
    static func liveRestoredReferences(
        _ required: BudgetActionUndo.RestoredReferences,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetActionUndo.RestoredReferences {
        var live = BudgetActionUndo.RestoredReferences()
        // A budget without the table cannot name a deleted row, so nothing is missing.
        if try database.tableExists("accounts", db: db) {
            for id in required.accountIDs {
                if try database.liveRowExists(table: "accounts", rowID: id, db: db) { live.accountIDs.insert(id) }
            }
        } else {
            live.accountIDs = required.accountIDs
        }
        if try database.tableExists("categories", db: db) {
            for id in required.categoryIDs {
                if try database.liveRowExists(table: "categories", rowID: id, db: db) { live.categoryIDs.insert(id) }
            }
        } else {
            live.categoryIDs = required.categoryIDs
        }
        return live
    }

    static func liveRuleActionsForUndo(
        learning: BudgetActionLearningSideEffect,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: String?] {
        guard !learning.isEmpty else { return [:] }
        let rules = try RuleSQL.fetchRules(in: database, db: db)
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.rawActionsJSON) })
        var live: [String: String?] = [:]
        for ruleID in learning.createdRuleIDs {
            live[ruleID] = byID[ruleID]
        }
        for update in learning.updatedRules {
            live[update.ruleID] = byID[update.ruleID]
        }
        return live
    }

    static func transactionUndoSnapshot(id: String, in database: isolated BudgetDatabase, db: Database) throws -> TransactionUndoSnapshot? {
        guard try database.tableExists("transactions", db: db) else { return nil }
        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        guard let row = try TransactionRowReader.row(id: id, db: db) else {
            return nil
        }
        let dateValue = SQLiteValueCoercion.int(row, "date") ?? 0
        let amount = SQLiteValueCoercion.int(row, "amount") ?? 0
        let payee = SQLiteValueCoercion.nonEmptyString(row, columns.payee)
        let category = SQLiteValueCoercion.nonEmptyString(row, "category")
        let notes = columns.hasNotes ? SQLiteValueCoercion.nonEmptyString(row, "notes") : nil
        let cleared = columns.hasCleared ? (SQLiteValueCoercion.int(row, "cleared") ?? 0) != 0 : false
        let tombstone = columns.hasTombstone ? (SQLiteValueCoercion.int(row, "tombstone") ?? 0) != 0 : false
        var isParent = false
        if let column = columns.isParent {
            isParent = (SQLiteValueCoercion.int(row, column) ?? 0) != 0
        }
        var isChild = false
        if let column = columns.isChild {
            isChild = (SQLiteValueCoercion.int(row, column) ?? 0) != 0
        }
        let parentID = TransactionRowReader.parentID(in: row, columns: columns)
        let transferID = columns.transferID.flatMap { SQLiteValueCoercion.nonEmptyString(row, $0) }
        return TransactionUndoSnapshot(
            id: id,
            accountID: SQLiteValueCoercion.nonEmptyString(row, columns.account) ?? "",
            dateValue: dateValue,
            amount: amount,
            payeeID: payee,
            categoryID: category,
            notes: notes,
            cleared: cleared,
            tombstone: tombstone,
            transferID: transferID,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID
        )
    }

    static func transactionUndoMessages(
        plan: BudgetActionUndoPlan,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        switch plan {
        case .assignments:
            return []
        case .tombstoneTransactions(let transactionIDs, let createdPayeeID, let learning):
            var messages: [ActualSyncDecodedMessage] = []
            for id in transactionIDs {
                messages.append(try builder.tombstone(dataset: "transactions", row: id))
            }
            messages += try learningUndoMessages(learning, builder: &builder, in: database, db: db)
            if let createdPayeeID,
               try createdPayeeIsUnused(createdPayeeID, ignoring: transactionIDs, in: database, db: db) {
                messages.append(
                    try builder.tombstone(dataset: "payees", row: createdPayeeID)
                )
            }
            return messages
        case .unTombstoneTransactions(let transactionIDs, let transferLinks):
            // Actual's delete clears the deleted leg's link, and its undo writes the link back
            // with the revive. A link the row still holds (deleted before the clear) is no write.
            let columns = try TransactionRowColumns.resolve(in: database, db: db)
            var messages: [ActualSyncDecodedMessage] = []
            for id in transactionIDs {
                messages.append(try builder.revive(dataset: "transactions", row: id))
                if let pairedID = transferLinks[id], let transferColumn = columns.transferID {
                    messages += try TransactionUndoCellDiff.changedCells(
                        [try builder.makeMessage(dataset: "transactions", row: id, column: transferColumn, value: .string(pairedID))],
                        currentRow: try TransactionRowReader.row(id: id, db: db),
                        flagColumns: TransactionUndoCellDiff.flagColumns(columns)
                    )
                }
            }
            return messages
        case .restoreSnapshots(let snapshots, let createdPayeeID, let learning):
            let columns = try TransactionRowColumns.resolve(in: database, db: db)
            var messages: [ActualSyncDecodedMessage] = []
            for snapshot in snapshots {
                let restored = try columns.rowMessages(
                    rowID: snapshot.id,
                    accountID: snapshot.accountID,
                    dateValue: snapshot.dateValue,
                    amountMinorUnits: snapshot.amount,
                    payeeID: snapshot.payeeID,
                    categoryID: snapshot.categoryID,
                    notes: snapshot.notes,
                    cleared: snapshot.cleared,
                    isParent: snapshot.isParent,
                    parentID: snapshot.parentID,
                    isChild: snapshot.isChild,
                    transferID: snapshot.transferID,
                    sortOrder: nil,
                    builder: &builder,
                    cells: .snapshot
                )
                messages += try TransactionUndoCellDiff.changedCells(
                    restored,
                    currentRow: try TransactionRowReader.row(id: snapshot.id, db: db),
                    flagColumns: TransactionUndoCellDiff.flagColumns(columns)
                )
            }
            messages += try learningUndoMessages(learning, builder: &builder, in: database, db: db)
            if let createdPayeeID,
               try createdPayeeIsUnused(createdPayeeID, ignoring: snapshots.map(\.id), in: database, db: db) {
                messages.append(
                    try builder.tombstone(dataset: "payees", row: createdPayeeID)
                )
            }
            return messages
        case .restoreBatchTransactions(let snapshots, let learning):
            let columns = try TransactionRowColumns.resolve(in: database, db: db)
            var messages: [ActualSyncDecodedMessage] = []
            for snapshot in snapshots {
                let restored = try TransactionBatchSnapshotSQL.transactionBatchRestoreMessages(
                    snapshot,
                    columns: columns,
                    builder: &builder
                )
                messages += try TransactionUndoCellDiff.changedCells(
                    restored,
                    currentRow: try TransactionRowReader.row(id: snapshot.id, db: db),
                    flagColumns: TransactionUndoCellDiff.flagColumns(columns)
                )
            }
            messages += try learningUndoMessages(learning, builder: &builder, in: database, db: db)
            return messages
        case .tombstoneDuplicateTransactions, .restoreMergedTransactions:
            return try TransactionCommandActionLogSQL.transactionCommandUndoMessages(plan: plan, builder: &builder, in: database, db: db)
        case .restoreCategories(let items, let learning):
            var messages: [ActualSyncDecodedMessage] = []
            for item in items {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: item.transactionID,
                        column: "category",
                        value: item.beforeCategoryID.map(LocalFirstSyncValue.string) ?? .null
                    )
                )
            }
            messages += try learningUndoMessages(learning, builder: &builder, in: database, db: db)
            return messages
        }
    }

    static func undoPreviewLines(
        record: BudgetActionRecord,
        plan: BudgetActionUndoPlan
    ) -> [BudgetActionUndoPreview.TransactionLine] {
        switch record.summary {
        case .createTransaction(let create):
            guard case .tombstoneTransactions = plan else { return [] }
            return [
                BudgetActionUndoPreview.TransactionLine(
                    id: record.id,
                    payeeName: create.payeeName,
                    amount: create.amount,
                    currentCategoryID: create.categoryID,
                    proposedCategoryID: nil,
                    effect: .delete
                )
            ]
        case .deleteTransaction(let delete):
            guard case .unTombstoneTransactions = plan else { return [] }
            return [
                BudgetActionUndoPreview.TransactionLine(
                    id: record.id,
                    payeeName: delete.payeeName,
                    amount: delete.amount,
                    currentCategoryID: delete.categoryID,
                    proposedCategoryID: delete.categoryID,
                    effect: .restore
                )
            ]
        case .editTransaction(let edit):
            guard case .restoreSnapshots = plan else { return [] }
            return [
                BudgetActionUndoPreview.TransactionLine(
                    id: record.id,
                    payeeName: edit.payeeName,
                    amount: edit.amountBefore,
                    currentCategoryID: nil,
                    proposedCategoryID: nil,
                    effect: .edit
                )
            ]
        case .categorize:
            guard case .restoreCategories(let items, _) = plan else { return [] }
            return items.map { item in
                BudgetActionUndoPreview.TransactionLine(
                    id: item.transactionID,
                    payeeName: nil,
                    amount: nil,
                    currentCategoryID: item.afterCategoryID,
                    proposedCategoryID: item.beforeCategoryID,
                    effect: .recategorize
                )
            }
        case .transactionBatch(let batch):
            guard case .restoreBatchTransactions = plan else { return [] }
            guard case .transactionBatch(let inverse) = record.inverse else { return [] }
            let afterByID = Dictionary(uniqueKeysWithValues: inverse.afterSnapshots.map { ($0.id, $0) })
            let beforeByID = Dictionary(uniqueKeysWithValues: inverse.beforeSnapshots.map { ($0.id, $0) })
            return inverse.selectedTransactionIDs.compactMap { id in
                guard let before = beforeByID[id], let after = afterByID[id] else { return nil }
                let effect: BudgetActionUndoPreview.TransactionLine.Effect
                switch batch.operation {
                case .clear: effect = .cleared
                case .categorize: effect = .recategorize
                case .delete: effect = .restore
                }
                return BudgetActionUndoPreview.TransactionLine(
                    id: id,
                    payeeName: nil,
                    amount: before.amount,
                    currentCategoryID: after.categoryID,
                    proposedCategoryID: before.categoryID,
                    effect: effect,
                    currentCleared: after.cleared,
                    proposedCleared: before.cleared
                )
            }
        case .transactionDuplicate:
            guard case .tombstoneDuplicateTransactions = plan else { return [] }
            return TransactionCommandActionLogSQL.transactionCommandUndoPreviewLines(record: record, plan: plan)
        case .transactionMerge:
            guard case .restoreMergedTransactions = plan else { return [] }
            return TransactionCommandActionLogSQL.transactionCommandUndoPreviewLines(record: record, plan: plan)
        case .assign, .move, .template, .payee, .rule, .account,
                .carryover, .learningPref, .transactionMetadata:
            return []
        }
    }

    private static func learningUndoMessages(
        _ learning: BudgetActionLearningSideEffect,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard !learning.isEmpty else { return [] }
        var messages: [ActualSyncDecodedMessage] = []
        if try database.tableExists("rules", db: db) {
            let columns = try database.columnSet(for: "rules", db: db)
            if columns.contains("tombstone") {
                for ruleID in learning.createdRuleIDs {
                    messages.append(
                        try builder.tombstone(dataset: "rules", row: ruleID)
                    )
                }
            }
            if columns.contains("actions") {
                for update in learning.updatedRules {
                    messages.append(
                        try builder.makeMessage(
                            dataset: "rules",
                            row: update.ruleID,
                            column: "actions",
                            value: .string(update.beforeActionsJSON)
                        )
                    )
                }
            }
        }
        return messages
    }

    private static func createdPayeeIsUnused(
        _ payeeID: String,
        ignoring transactionIDs: [String],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Bool {
        guard try database.tableExists("transactions", db: db) else { return true }
        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        let ignored = transactionIDs.filter { !$0.isEmpty }
        let ignoreSQL: String
        let arguments: [any DatabaseValueConvertible]
        if ignored.isEmpty {
            ignoreSQL = ""
            arguments = [payeeID]
        } else {
            let placeholders = Array(repeating: "?", count: ignored.count).joined(separator: ",")
            ignoreSQL = "AND id NOT IN (\(placeholders))"
            arguments = [payeeID] + ignored
        }
        let count = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM transactions
                WHERE \(columns.payee) = ?
                  AND \(database.predicateForLiveRows(columns: columns.all))
                  \(ignoreSQL)
                """,
            arguments: StatementArguments(arguments)
        ) ?? 0
        return count == 0
    }

    private static func graphKind(from snapshot: TransactionUndoSnapshot) -> BudgetTransactionGraphKind {
        if snapshot.isParent { return .split }
        if snapshot.transferID != nil { return .transfer }
        return .simple
    }

    private static func decodedSyncString(_ serialized: String) -> String? {
        if serialized.hasPrefix("S:") {
            return String(serialized.dropFirst(2))
        }
        return nil
    }
}
