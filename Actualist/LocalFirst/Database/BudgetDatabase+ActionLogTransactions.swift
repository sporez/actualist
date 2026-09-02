import Foundation
import GRDB

extension BudgetDatabase {
    func captureTransactionActionLogFacts(
        descriptor: BudgetActionDescriptor,
        db: Database
    ) throws -> ActionLogFacts {
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
            return ActionLogFacts(
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
            return ActionLogFacts(
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
            guard let primaryBefore = try transactionUndoSnapshot(id: edit.transactionID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing transaction")
            }
            var relatedBefore: [TransactionUndoSnapshot] = []
            for relatedID in edit.affectedIDs where relatedID != edit.transactionID {
                if let snapshot = try transactionUndoSnapshot(id: relatedID, db: db) {
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
            return ActionLogFacts(
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
            return ActionLogFacts(
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

        case .assign, .move, .template:
            throw LocalFirstError.invalidLocalWrite("unexpected budget action in transaction capture")
        }
    }

    func completeActionLogFacts(
        _ facts: ActionLogFacts,
        descriptor: BudgetActionDescriptor,
        db: Database
    ) throws -> ActionLogFacts {
        guard case .editTransaction(let edit) = descriptor,
              case .editTransaction(var inverse) = facts.inverse else {
            return facts
        }
        guard let primaryAfter = try transactionUndoSnapshot(id: edit.transactionID, db: db) else {
            return facts
        }
        var relatedAfter: [TransactionUndoSnapshot] = []
        for relatedID in edit.affectedIDs where relatedID != edit.transactionID {
            if let snapshot = try transactionUndoSnapshot(id: relatedID, db: db) {
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

    func learningSideEffect(
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

    func liveTransactionsForUndo(
        ids: [String],
        db: Database
    ) throws -> [String: TransactionUndoSnapshot?] {
        var pending = ids
        var live: [String: TransactionUndoSnapshot?] = [:]
        var seen = Set<String>()
        while let id = pending.first {
            pending.removeFirst()
            guard seen.insert(id).inserted else { continue }
            let snapshot = try transactionUndoSnapshot(id: id, db: db)
            live[id] = snapshot
            if let snapshot, snapshot.isParent,
               try tableExists("transactions", db: db) {
                let columns = try resolveTransactionRowColumns(db: db)
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

    func liveRuleActionsForUndo(
        learning: BudgetActionLearningSideEffect,
        db: Database
    ) throws -> [String: String?] {
        guard !learning.isEmpty else { return [:] }
        let rules = try fetchRules(db: db)
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

    func transactionUndoSnapshot(id: String, db: Database) throws -> TransactionUndoSnapshot? {
        guard try tableExists("transactions", db: db) else { return nil }
        let columns = try resolveTransactionRowColumns(db: db)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM transactions WHERE id = ?",
            arguments: [id]
        ) else {
            return nil
        }
        let dateValue = intValue(row, "date") ?? 0
        let amount = intValue(row, "amount") ?? 0
        let payee = stringValue(row, columns.payee)
        let category = stringValue(row, "category")
        let notes = columns.hasNotes ? stringValue(row, "notes") : nil
        let cleared = columns.hasCleared ? (intValue(row, "cleared") ?? 0) != 0 : false
        let tombstone = columns.hasTombstone ? (intValue(row, "tombstone") ?? 0) != 0 : false
        var isParent = false
        if let column = columns.isParent {
            isParent = (intValue(row, column) ?? 0) != 0
        }
        var isChild = false
        if let column = columns.isChild {
            isChild = (intValue(row, column) ?? 0) != 0
        }
        let parentID = columns.hasParentID ? stringValue(row, "parent_id") : nil
        let transferID = columns.transferID.flatMap { stringValue(row, $0) }
        return TransactionUndoSnapshot(
            id: id,
            accountID: stringValue(row, columns.account) ?? "",
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

    func transactionUndoMessages(
        plan: BudgetActionUndoPlan,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        switch plan {
        case .assignments:
            return []
        case .tombstoneTransactions(let transactionIDs, let createdPayeeID, let learning):
            var messages: [ActualSyncDecodedMessage] = []
            for id in transactionIDs {
                messages.append(try tombstoneMessage(rowID: id, builder: &builder))
            }
            messages += try learningUndoMessages(learning, db: db, builder: &builder)
            if let createdPayeeID,
               try createdPayeeIsUnused(createdPayeeID, ignoring: transactionIDs, db: db) {
                messages.append(
                    try builder.makeMessage(
                        dataset: "payees",
                        row: createdPayeeID,
                        column: "tombstone",
                        value: .bool(true)
                    )
                )
            }
            return messages
        case .unTombstoneTransactions(let transactionIDs):
            return try transactionIDs.map { id in
                try builder.makeMessage(
                    dataset: "transactions",
                    row: id,
                    column: "tombstone",
                    value: .bool(false)
                )
            }
        case .restoreSnapshots(let snapshots, let createdPayeeID, let learning):
            let columns = try resolveTransactionRowColumns(db: db)
            var messages: [ActualSyncDecodedMessage] = []
            for snapshot in snapshots {
                messages += try transactionRowMessages(
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
                    columns: columns,
                    builder: &builder
                )
            }
            messages += try learningUndoMessages(learning, db: db, builder: &builder)
            if let createdPayeeID,
               try createdPayeeIsUnused(createdPayeeID, ignoring: snapshots.map(\.id), db: db) {
                messages.append(
                    try builder.makeMessage(
                        dataset: "payees",
                        row: createdPayeeID,
                        column: "tombstone",
                        value: .bool(true)
                    )
                )
            }
            return messages
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
            messages += try learningUndoMessages(learning, db: db, builder: &builder)
            return messages
        }
    }

    func undoPreviewLines(
        record: BudgetActionRecord,
        plan: BudgetActionUndoPlan
    ) -> [BudgetActionUndoPreview.TransactionLine] {
        switch (record.summary, plan) {
        case (.createTransaction(let create), .tombstoneTransactions):
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
        case (.deleteTransaction(let delete), .unTombstoneTransactions):
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
        case (.editTransaction(let edit), .restoreSnapshots):
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
        case (.categorize, .restoreCategories(let items, _)):
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
        default:
            return []
        }
    }

    private func learningUndoMessages(
        _ learning: BudgetActionLearningSideEffect,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard !learning.isEmpty else { return [] }
        var messages: [ActualSyncDecodedMessage] = []
        if try tableExists("rules", db: db) {
            let columns = try columnSet(for: "rules", db: db)
            if columns.contains("tombstone") {
                for ruleID in learning.createdRuleIDs {
                    messages.append(
                        try builder.makeMessage(
                            dataset: "rules",
                            row: ruleID,
                            column: "tombstone",
                            value: .bool(true)
                        )
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

    private func createdPayeeIsUnused(
        _ payeeID: String,
        ignoring transactionIDs: [String],
        db: Database
    ) throws -> Bool {
        guard try tableExists("transactions", db: db) else { return true }
        let columns = try resolveTransactionRowColumns(db: db)
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
                  AND \(predicateForLiveRows(columns: columns.all))
                  \(ignoreSQL)
                """,
            arguments: StatementArguments(arguments)
        ) ?? 0
        return count == 0
    }

    private func graphKind(from snapshot: TransactionUndoSnapshot) -> BudgetTransactionGraphKind {
        if snapshot.isParent { return .split }
        if snapshot.transferID != nil { return .transfer }
        return .simple
    }

    private func intValue(_ row: Row, _ column: String) -> Int? {
        if let value = row[column] as Int? { return value }
        if let value = row[column] as Int64? { return Int(value) }
        if let value = row[column] as String? { return Int(value) }
        return nil
    }

    private func stringValue(_ row: Row, _ column: String) -> String? {
        guard let value = row[column] as String?, !value.isEmpty else { return nil }
        return value
    }

    private func decodedSyncString(_ serialized: String) -> String? {
        if serialized.hasPrefix("S:") {
            return String(serialized.dropFirst(2))
        }
        return nil
    }
}
