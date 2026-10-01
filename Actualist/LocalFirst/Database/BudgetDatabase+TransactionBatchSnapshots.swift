import Foundation
import GRDB

struct TransactionBatchGraphSnapshot {
    let snapshots: [String: TransactionBatchTransactionSnapshot]
    let invalidReason: String?
}

extension BudgetDatabase {
    func transactionBatchGraph(
        containing transactionID: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> TransactionBatchGraphSnapshot {
        var snapshots: [String: TransactionBatchTransactionSnapshot] = [:]
        var pending = [transactionID]
        var invalidReason: String?
        while let id = pending.popLast() {
            guard snapshots[id] == nil else { continue }
            guard let snapshot = try transactionBatchSnapshot(id: id, columns: columns, db: db) else {
                invalidReason = "A transaction in the selected graph is missing."
                continue
            }
            snapshots[id] = snapshot
            if snapshot.tombstone == true {
                invalidReason = "A transaction in the selected graph is no longer available."
            }
            if snapshot.accountID?.isEmpty != false || snapshot.dateValue == nil || snapshot.amount == nil {
                invalidReason = "A transaction in the selected graph is missing required row data."
            }
            if snapshot.isChild == true {
                guard let parentID = snapshot.parentID, !parentID.isEmpty,
                      let parent = try transactionBatchSnapshot(id: parentID, columns: columns, db: db),
                      parent.isParent == true else {
                    invalidReason = "The selected split entry has no valid parent."
                    continue
                }
                pending.append(parentID)
            } else if let parentID = snapshot.parentID, !parentID.isEmpty {
                invalidReason = "A transaction has a parent link without a split-entry identity."
            }
            if snapshot.isParent == true {
                guard columns.hasParentID else {
                    invalidReason = "This split graph cannot be inspected with the current schema."
                    continue
                }
                let childIDs = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM transactions WHERE parent_id = ? AND \(predicateForLiveRows(columns: columns.all))",
                    arguments: [id]
                )
                guard !childIDs.isEmpty else {
                    invalidReason = "The selected split has no live entries."
                    continue
                }
                for childID in childIDs {
                    guard let child = try transactionBatchSnapshot(id: childID, columns: columns, db: db),
                          child.isChild == true,
                          child.parentID == id else {
                        invalidReason = "The selected split contains a malformed entry."
                        continue
                    }
                    pending.append(childID)
                }
            } else if columns.hasParentID {
                let liveChildren = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM transactions WHERE parent_id = ? AND \(predicateForLiveRows(columns: columns.all))",
                    arguments: [id]
                ) ?? 0
                if liveChildren > 0 {
                    invalidReason = "The selected transaction has split entries but is not marked as their parent."
                }
            }
            if let transferID = snapshot.transferID {
                guard let pair = try transactionBatchSnapshot(id: transferID, columns: columns, db: db),
                      pair.transferID == snapshot.id,
                      pair.tombstone != true else {
                    invalidReason = "The selected transfer pair is incomplete or malformed."
                    continue
                }
                guard transferID != snapshot.id,
                      let accountID = snapshot.accountID, !accountID.isEmpty,
                      let pairedAccountID = pair.accountID, !pairedAccountID.isEmpty,
                      accountID != pairedAccountID,
                      let amount = snapshot.amount, amount != Int.min,
                      let pairedAmount = pair.amount, pairedAmount == -amount else {
                    invalidReason = "The selected transfer pair is incomplete or malformed."
                    continue
                }
                pending.append(transferID)
            }
            if let transferColumn = columns.transferID {
                let incomingIDs = try transactionBatchLiveIncomingTransferIDs(
                    to: id,
                    transferColumn: transferColumn,
                    columns: columns,
                    db: db
                )
                let expectedIncoming = snapshot.transferID.map { Set([$0]) } ?? []
                if incomingIDs != expectedIncoming {
                    invalidReason = "The selected transfer pair has a missing, nonreciprocal, or extra backlink."
                }
                pending.append(contentsOf: incomingIDs.sorted())
            }
            if let error = snapshot.splitError,
               !error.isEmpty,
               error != "null",
               parseSplitTransactionError(error) == nil {
                invalidReason = "The split error data cannot be interpreted safely."
            }
        }
        return TransactionBatchGraphSnapshot(snapshots: snapshots, invalidReason: invalidReason)
    }

    func transactionBatchSnapshot(
        id: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> TransactionBatchTransactionSnapshot? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM transactions WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        let available = columns.all
        func string(_ name: String) -> String? {
            guard available.contains(name) else { return nil }
            return row[name] as String?
        }
        func integer(_ name: String) -> Int? {
            guard available.contains(name) else { return nil }
            if let value = row[name] as Int? { return value }
            if let value = row[name] as Int64? { return Int(value) }
            if let value = row[name] as String? { return Int(value) }
            return nil
        }
        func packedDate(_ name: String) -> Int? {
            if let value = integer(name) { return value }
            guard available.contains(name), let raw = row[name] as String? else { return nil }
            let digits = raw.filter(\.isNumber)
            return digits.count == 8 ? Int(digits) : nil
        }
        func flag(_ name: String) -> Bool? {
            guard available.contains(name) else { return nil }
            if let value = integer(name) { return value != 0 }
            if let value = row[name] as String? {
                switch value.lowercased() {
                case "true", "yes": return true
                case "false", "no": return false
                default: return nil
                }
            }
            return nil
        }
        func double(_ name: String?) -> Double? {
            guard let name, available.contains(name) else { return nil }
            if let value = row[name] as Double? { return value }
            if let value = row[name] as Int? { return Double(value) }
            if let value = row[name] as String? { return Double(value) }
            return nil
        }
        let parentID = string("parent_id")
        let isChild = effectiveIsChild(row: row, columns: columns, parentID: parentID)
        return TransactionBatchTransactionSnapshot(
            id: id,
            columns: available.sorted(),
            accountID: string(columns.account),
            dateValue: packedDate("date"),
            amount: integer("amount"),
            payeeID: string(columns.payee),
            categoryID: string("category"),
            notes: string("notes"),
            cleared: flag("cleared"),
            reconciled: flag("reconciled"),
            tombstone: flag("tombstone"),
            isParent: columns.isParent.flatMap(flag),
            isChild: isChild,
            parentID: parentID,
            transferID: columns.transferID.flatMap(string),
            sortOrder: double(columns.sortOrder),
            splitError: string("error"),
            startingBalance: flag("starting_balance_flag"),
            scheduleID: string("schedule"),
            importedID: string("financial_id"),
            importedPayee: string("imported_payee"),
            importedDescription: string("imported_description")
        )
    }

    func transactionBatchSnapshots(
        ids: [String],
        db: Database
    ) throws -> [TransactionBatchTransactionSnapshot] {
        let columns = try resolveTransactionRowColumns(db: db)
        var output: [TransactionBatchTransactionSnapshot] = []
        for id in Set(ids).sorted() {
            guard let snapshot = try transactionBatchSnapshot(id: id, columns: columns, db: db) else {
                continue
            }
            output.append(snapshot)
        }
        return output
    }

    func transactionBatchLiveCategoryExists(id: String, db: Database) throws -> Bool {
        guard try tableExists("categories", db: db) else { return false }
        let columns = try columnSet(for: "categories", db: db)
        guard columns.contains("id") else { return false }
        return try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM categories WHERE id = ? AND \(predicateForLiveRows(columns: columns)))",
            arguments: [id]
        ) ?? false
    }

    func transactionBatchGraphMembershipMatches(
        _ snapshots: [TransactionBatchTransactionSnapshot],
        db: Database
    ) throws -> Bool {
        let columns = try resolveTransactionRowColumns(db: db)
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        let rootIDs = Set(snapshots.compactMap { snapshot -> String? in
            if snapshot.isParent == true { return snapshot.id }
            return snapshot.parentID
        })
        for rootID in rootIDs {
            guard columns.hasParentID else { return false }
            let liveIDs = Set(try String.fetchAll(
                db,
                sql: "SELECT id FROM transactions WHERE parent_id = ? AND \(predicateForLiveRows(columns: columns.all))",
                arguments: [rootID]
            ))
            let expectedIDs = Set(snapshots.compactMap { snapshot -> String? in
                snapshot.parentID == rootID && snapshot.tombstone != true ? snapshot.id : nil
            })
            guard liveIDs == expectedIDs, byID[rootID] != nil else { return false }
        }
        for snapshot in snapshots where snapshot.tombstone != true {
            if let pairedID = snapshot.transferID {
                guard let paired = byID[pairedID],
                      paired.tombstone != true,
                      paired.transferID == snapshot.id else { return false }
            }
        }
        if let transferColumn = columns.transferID {
            for snapshot in snapshots {
                let liveIncoming = try transactionBatchLiveIncomingTransferIDs(
                    to: snapshot.id,
                    transferColumn: transferColumn,
                    columns: columns,
                    db: db
                )
                let expectedIncoming = Set(snapshots.compactMap { candidate -> String? in
                    candidate.tombstone != true && candidate.transferID == snapshot.id ? candidate.id : nil
                })
                guard liveIncoming == expectedIncoming else { return false }
            }
        }
        return true
    }

    private func transactionBatchLiveIncomingTransferIDs(
        to transactionID: String,
        transferColumn: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> Set<String> {
        Set(try String.fetchAll(
            db,
            sql: "SELECT id FROM transactions WHERE \(quotedIdentifier(transferColumn)) = ? AND \(predicateForLiveRows(columns: columns.all))",
            arguments: [transactionID]
        ))
    }

    func transactionBatchRestoreMessages(
        _ snapshot: TransactionBatchTransactionSnapshot,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let required = [columns.account, columns.payee, "date", "amount", "category"]
        guard required.allSatisfy(snapshot.columns.contains),
              required.allSatisfy(columns.all.contains) else {
            throw LocalFirstError.actionUndoBlocked(BudgetActionUndoBlock.batchChanged.userFacingReason)
        }
        func message(_ column: String, _ value: LocalFirstSyncValue) throws -> ActualSyncDecodedMessage {
            guard snapshot.columns.contains(column), columns.all.contains(column) else {
                throw LocalFirstError.actionUndoBlocked(BudgetActionUndoBlock.batchChanged.userFacingReason)
            }
            return try builder.makeMessage(dataset: "transactions", row: snapshot.id, column: column, value: value)
        }
        func stringValue(_ value: String?) -> LocalFirstSyncValue { value.map(LocalFirstSyncValue.string) ?? .null }
        func boolValue(_ value: Bool?) -> LocalFirstSyncValue { value.map(LocalFirstSyncValue.bool) ?? .null }
        var messages: [ActualSyncDecodedMessage] = [
            try message(columns.account, stringValue(snapshot.accountID)),
            try message("date", snapshot.dateValue.map { .int(Int64($0)) } ?? .null),
            try message("amount", snapshot.amount.map { .int(Int64($0)) } ?? .null),
            try message(columns.payee, stringValue(snapshot.payeeID)),
            try message("category", stringValue(snapshot.categoryID)),
        ]
        if snapshot.columns.contains("notes") { messages.append(try message("notes", stringValue(snapshot.notes))) }
        if snapshot.columns.contains("cleared") { messages.append(try message("cleared", boolValue(snapshot.cleared))) }
        if snapshot.columns.contains("reconciled") { messages.append(try message("reconciled", boolValue(snapshot.reconciled))) }
        if let parentColumn = columns.isParent, snapshot.columns.contains(parentColumn) {
            messages.append(try message(parentColumn, boolValue(snapshot.isParent)))
        }
        if snapshot.columns.contains("parent_id") { messages.append(try message("parent_id", stringValue(snapshot.parentID))) }
        if let childColumn = columns.isChild, snapshot.columns.contains(childColumn) {
            messages.append(try message(childColumn, boolValue(snapshot.isChild)))
        }
        if let transferColumn = columns.transferID, snapshot.columns.contains(transferColumn) {
            messages.append(try message(transferColumn, stringValue(snapshot.transferID)))
        }
        if let sortColumn = columns.sortOrder, snapshot.columns.contains(sortColumn) {
            messages.append(try message(sortColumn, snapshot.sortOrder.map(LocalFirstSyncValue.double) ?? .null))
        }
        if snapshot.columns.contains("error") { messages.append(try message("error", stringValue(snapshot.splitError))) }
        if snapshot.columns.contains("starting_balance_flag") {
            messages.append(try message("starting_balance_flag", boolValue(snapshot.startingBalance)))
        }
        if snapshot.columns.contains("schedule") { messages.append(try message("schedule", stringValue(snapshot.scheduleID))) }
        if snapshot.columns.contains("financial_id") { messages.append(try message("financial_id", stringValue(snapshot.importedID))) }
        if snapshot.columns.contains("imported_payee") { messages.append(try message("imported_payee", stringValue(snapshot.importedPayee))) }
        if snapshot.columns.contains("imported_description") { messages.append(try message("imported_description", stringValue(snapshot.importedDescription))) }
        if snapshot.columns.contains("tombstone") { messages.append(try message("tombstone", boolValue(snapshot.tombstone))) }
        return messages
    }
}
