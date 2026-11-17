import Foundation
import GRDB

enum SplitFamilySQL {
    static func createSplitTransactionMessages(
        draft: TransactionDraft,
        parentTransactionID: String,
        payeeID: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try createSplitFamilyWrite(
            draft: draft,
            parentTransactionID: parentTransactionID,
            payeeID: payeeID,
            builder: &builder,
            in: database
        ).messages
    }

    static func createSplitFamilyWrite(
        draft: TransactionDraft,
        parentTransactionID: String,
        payeeID: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> BudgetDatabase.TransactionWriteResult {
        try database.queue.read { db in
            try TransactionCreationSQL.createSplitFamilyWrite(
                draft: draft,
                parentTransactionID: parentTransactionID,
                payeeID: payeeID,
                builder: &builder,
                in: database,
                db: db
            )
        }
    }

    /// Import/schedule identity lives on the parent only. Family records do
    /// not carry `financial_id` / `imported_payee` / `schedule`; simple-create
    /// writes those columns, and split-create must too or Wallet/Bank Sync
    /// duplicates and imported-payee rules silently break.
    static func appendingSplitParentImportMetadata(
        to result: BudgetDatabase.TransactionWriteResult,
        parentTransactionID: String,
        draft: TransactionDraft,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> BudgetDatabase.TransactionWriteResult {
        var messages = result.messages
        if let importedPayee = draft.importedPayee, !importedPayee.isEmpty,
           let column = TransactionRowColumns.importedPayee(in: columns.all) {
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: parentTransactionID,
                    column: column,
                    value: .string(importedPayee)
                )
            )
        }
        if let importedID = draft.importedID, !importedID.isEmpty,
           let column = TransactionRowColumns.importedID(in: columns.all) {
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: parentTransactionID,
                    column: column,
                    value: .string(importedID)
                )
            )
        }
        if let scheduleID = draft.scheduleID, !scheduleID.isEmpty, columns.hasSchedule {
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: parentTransactionID,
                    column: "schedule",
                    value: .string(scheduleID)
                )
            )
        }
        return BudgetDatabase.TransactionWriteResult(
            messages: messages,
            affectedAccountIDs: result.affectedAccountIDs,
            affectedTransactionIDs: result.affectedTransactionIDs
        )
    }

    static func splitFamilyUpdateMessages(
        transactionID: String,
        draft: TransactionDraft,
        payeeID: String?,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetDatabase.TransactionWriteResult {
        try validateSplitCategories(draft.splits, in: database, db: db)
        let oldRows = try loadSplitFamily(containing: transactionID, columns: columns, in: database, db: db)
        guard let current = oldRows.first(where: { $0.id == transactionID }) ?? oldRows.first else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }

        if current.isChild && !draft.isSplit {
            var child = current
            child.amount = draft.amountMinorUnits
            child.category = draft.categoryID
            child.payee = payeeID ?? child.payee
            child.notes = draft.notes
            child.cleared = draft.cleared
            child.reconciled = draft.reconciled
            let result = SplitTransactionFamilyOps.updateTransaction(oldRows, transaction: child)
            return try persistFamilyChange(
                oldRows: oldRows,
                newRows: result.data,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
        }

        if !draft.isSplit {
            let simple = try splitParentRecord(
                id: current.isParent ? current.id : transactionID,
                draft: draft,
                payeeID: payeeID,
                inheritFrom: current
            )
            return try persistFamilyChange(
                oldRows: oldRows,
                newRows: [simple],
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
        }

        let converting = !current.isParent && !current.isChild
        try validateSplitDraftIDs(
            draft.splits,
            parentID: current.isChild ? (current.parentID ?? current.id) : current.id,
            familyChildIDs: Set(oldRows.filter(\.isChild).map(\.id)),
            in: database,
            db: db
        )
        var parent = try splitParentRecord(
            id: current.isChild ? (current.parentID ?? current.id) : current.id,
            draft: draft,
            payeeID: payeeID,
            inheritFrom: oldRows.first(where: \.isParent) ?? current
        )
        if let payeeID {
            parent.payee = payeeID
        } else if converting {
            parent.payee = nil
        }
        parent.category = converting ? draft.categoryID : nil
        let family = materializeSplitFamily(
            parent: parent,
            drafts: draft.splits,
            existingChildren: oldRows.filter(\.isChild),
            nullParentPayee: converting
        )
        let overlay = family
        let result = converting
            ? SplitTransactionChangeSet(
                data: SplitTransactionFamilyOps.ungroupTransaction(overlay),
                newTransaction: overlay,
                diff: SplitTransactionFamilyOps.diffItems(oldRows, SplitTransactionFamilyOps.ungroupTransaction(overlay))
            )
            : SplitTransactionFamilyOps.updateTransaction(oldRows, transaction: overlay)
        return try persistFamilyChange(
            oldRows: oldRows,
            newRows: result.data,
            columns: columns,
            builder: &builder,
            in: database,
            db: db
        )
    }

    static func deleteSplitFamilyMessages(
        transactionID: String,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetDatabase.TransactionWriteResult {
        let oldRows = try loadSplitFamily(containing: transactionID, columns: columns, in: database, db: db)
        guard !oldRows.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        let result = SplitTransactionFamilyOps.deleteTransaction(oldRows, id: transactionID)
        return try persistFamilyChange(
            oldRows: oldRows,
            newRows: result.data,
            columns: columns,
            builder: &builder,
            in: database,
            db: db
        )
    }

    static func materializeSplitFamily(
        parent: SplitTransactionRecord,
        drafts: [TransactionSplitDraft],
        existingChildren: [SplitTransactionRecord],
        nullParentPayee: Bool
    ) -> SplitTransactionRecord {
        let children = drafts.enumerated().map { index, draft in
            var child = SplitTransactionFamilyOps.makeChild(
                parent: parent,
                data: childPatch(draft, existing: existingChildren, index: index)
            )
            // `makeChild` matches Actual's family oracle and always clears
            // transferID. Persistence must keep the existing pair.
            if let existing = existingChildren.first(where: { $0.id == child.id }) {
                child.transferID = existing.transferID
            }
            return child
        }
        var family = parent
        family.isParent = true
        family.isChild = false
        family.parentID = nil
        family.category = nil
        if nullParentPayee {
            family.payee = nil
        }
        family.subtransactions = children
        return SplitTransactionFamilyOps.recalculateSplit(family)
    }

    private static func childPatch(
        _ draft: TransactionSplitDraft,
        existing: [SplitTransactionRecord],
        index: Int
    ) -> SplitTransactionPatch {
        let current = draft.id.flatMap { id in existing.first { $0.id == id } }
        var patch = SplitTransactionPatch(
            id: draft.id ?? current?.id,
            amount: draft.amountMinorUnits,
            category: .value(draft.categoryID)
        )
        switch draft.payeeID {
        case .omitted:
            if let current { patch.payee = .value(current.payee) }
        case .value(let value):
            patch.payee = .value(value)
        }
        switch draft.notes {
        case .omitted:
            if let current { patch.notes = .value(current.notes) }
        case .value(let value):
            patch.notes = .value(value)
        }
        switch draft.sortOrder {
        case .omitted:
            if let current {
                patch.sortOrder = .value(current.sortOrder)
            } else {
                patch.sortOrder = .value(Double(-(index + 1)))
            }
        case .value(let value):
            patch.sortOrder = .value(value ?? Double(-(index + 1)))
        }
        return patch
    }

    static func splitParentRecord(
        id: String,
        draft: TransactionDraft,
        payeeID: String?,
        inheritFrom: SplitTransactionRecord?
    ) throws -> SplitTransactionRecord {
        let dateValue = try BudgetDatabase.actualDateValue(draft.date)
        return SplitTransactionRecord(
            id: id,
            amount: draft.amountMinorUnits,
            account: draft.accountID,
            date: PackedDate.iso(dateValue),
            category: draft.categoryID,
            payee: payeeID,
            notes: draft.notes,
            cleared: draft.cleared,
            reconciled: draft.reconciled,
            startingBalance: inheritFrom?.startingBalance,
            sortOrder: draft.sortOrder ?? inheritFrom?.sortOrder,
            isParent: false,
            isChild: false,
            parentID: nil,
            transferID: inheritFrom?.transferID,
            error: nil,
            deleted: false
        )
    }

    static func validateSplitCategories(_ splits: [TransactionSplitDraft], in database: isolated BudgetDatabase, db: Database) throws {
        guard try database.tableExists("categories", db: db) else { return }
        for split in splits {
            if let categoryID = split.categoryID,
               try !database.liveRowExists(table: "categories", rowID: categoryID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
        }
    }

    static func persistFamilyChange(
        oldRows: [SplitTransactionRecord],
        newRows: [SplitTransactionRecord],
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetDatabase.TransactionWriteResult {
        let oldByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0) })
        var deletedIDs = Set(oldByID.keys).subtracting(newByID.keys)
        if let oldParent = oldRows.first(where: \.isParent), newByID[oldParent.id] == nil {
            deletedIDs.formUnion(oldRows.map(\.id))
        }
        let addedIDs = Set(newByID.keys).subtracting(oldByID.keys)
        let updatedIDs = Set(newByID.keys).intersection(oldByID.keys)

        var messages: [ActualSyncDecodedMessage] = []
        var affectedAccounts = Set(oldRows.compactMap(\.account) + newRows.compactMap(\.account))
        var affectedTransactions = deletedIDs.union(addedIDs).union(updatedIDs)

        for id in addedIDs.sorted() {
            guard let row = newByID[id] else { continue }
            let prepared = try TransferSQL.prepareTransferOnInsert(
                row,
                columns: columns,
                affectedAccounts: &affectedAccounts,
                affectedTransactions: &affectedTransactions,
                builder: &builder,
                in: database,
                db: db
            )
            messages += prepared.messages
            messages += try messagesForNewRow(
                prepared.row,
                columns: columns,
                builder: &builder
            )
        }

        for id in updatedIDs.sorted() {
            guard let old = oldByID[id], let new = newByID[id] else { continue }
            messages += try messagesForChangedFields(
                from: old,
                to: new,
                columns: columns,
                builder: &builder
            )
            let transfer = try TransferSQL.transferMessagesOnUpdate(
                old: old,
                new: new,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
            messages += transfer.messages
            affectedAccounts.formUnion(transfer.accounts)
            affectedTransactions.formUnion(transfer.transactions)
        }

        for id in deletedIDs.sorted() {
            guard let old = oldByID[id] else { continue }
            if columns.hasTombstone {
                messages.append(try builder.tombstone(dataset: "transactions", row: id))
            }
            let transfer = try TransferSQL.transferMessagesOnDelete(
                old,
                columns: columns,
                builder: &builder,
                db: db
            )
            messages += transfer.messages
            affectedAccounts.formUnion(transfer.accounts)
            affectedTransactions.formUnion(transfer.transactions)
        }

        return BudgetDatabase.TransactionWriteResult(
            messages: messages,
            affectedAccountIDs: Array(affectedAccounts),
            affectedTransactionIDs: Array(affectedTransactions)
        )
    }

    private static func messagesForNewRow(
        _ row: SplitTransactionRecord,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try columns.rowMessages(
            rowID: row.id,
            accountID: row.account ?? "",
            dateValue: PackedDate.packed(fromISO: row.date),
            amountMinorUnits: row.amount,
            payeeID: row.payee,
            categoryID: row.isParent ? nil : row.category,
            notes: row.notes,
            cleared: row.cleared ?? false,
            reconciled: row.reconciled,
            isParent: row.isParent,
            parentID: row.parentID,
            isChild: row.isChild,
            transferID: row.transferID,
            sortOrder: row.sortOrder,
            error: row.isParent ? row.error : nil,
            startingBalance: row.startingBalance,
            builder: &builder,
            cells: .snapshot
        )
    }

    static func messagesForChangedFields(
        from old: SplitTransactionRecord,
        to new: SplitTransactionRecord,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        var fields: [(String, LocalFirstSyncValue)] = []
        if old.account != new.account {
            fields.append((columns.account, new.account.map(LocalFirstSyncValue.string) ?? .null))
        }
        if old.date != new.date {
            fields.append(("date", .int(Int64(PackedDate.packed(fromISO: new.date)))))
        }
        if old.amount != new.amount {
            fields.append(("amount", .int(Int64(new.amount))))
        }
        if old.payee != new.payee {
            fields.append((columns.payee, new.payee.map(LocalFirstSyncValue.string) ?? .null))
        }
        let newCategory = new.isParent ? nil : new.category
        let oldCategory = old.isParent ? nil : old.category
        if oldCategory != newCategory {
            fields.append(("category", newCategory.map(LocalFirstSyncValue.string) ?? .null))
        }
        // NULL and '' are the same note: an untouched empty field is no change.
        if columns.hasNotes, (old.notes ?? "") != (new.notes ?? "") {
            fields.append(("notes", new.notes.map(LocalFirstSyncValue.string) ?? .null))
        }
        if columns.hasCleared, old.cleared != new.cleared {
            fields.append(("cleared", .bool(new.cleared ?? false)))
        }
        if columns.hasReconciled, old.reconciled != new.reconciled {
            fields.append(("reconciled", .bool(new.reconciled ?? false)))
        }
        if let isParentColumn = columns.isParent, old.isParent != new.isParent {
            fields.append((isParentColumn, .bool(new.isParent)))
        }
        if columns.hasParentID, old.parentID != new.parentID {
            fields.append(("parent_id", new.parentID.map(LocalFirstSyncValue.string) ?? .null))
        }
        if let isChildColumn = columns.isChild, old.isChild != new.isChild {
            fields.append((isChildColumn, .bool(new.isChild)))
        }
        if let sortColumn = columns.sortOrder, old.sortOrder != new.sortOrder, let sortOrder = new.sortOrder {
            fields.append((sortColumn, .double(sortOrder)))
        }
        if columns.hasError, old.error != new.error {
            fields.append(("error", SplitTransactionError.syncValue(new.isParent ? new.error : nil)))
        }
        if columns.hasStartingBalance, old.startingBalance != new.startingBalance {
            fields.append(("starting_balance_flag", .bool(new.startingBalance ?? false)))
        }
        if old.deleted != new.deleted, columns.hasTombstone {
            fields.append(("tombstone", .bool(new.deleted)))
        }
        var messages: [ActualSyncDecodedMessage] = []
        for (column, value) in fields {
            messages.append(
                try builder.makeMessage(dataset: "transactions", row: new.id, column: column, value: value)
            )
        }
        return messages
    }

    static func loadSplitFamily(
        containing id: String,
        columns: TransactionRowColumns,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [SplitTransactionRecord] {
        guard let current = try loadTransactionRecord(id: id, columns: columns, db: db) else {
            return []
        }
        let parentID = current.isChild ? (current.parentID ?? id) : id
        guard let parent = try loadTransactionRecord(id: parentID, columns: columns, db: db) else {
            return [current]
        }
        let children = try loadChildRecords(parentID: parent.id, columns: columns, in: database, db: db)
        var parentRow = parent
        parentRow.subtransactions = []
        return [parentRow] + children
    }

    private static func loadChildRecords(
        parentID: String,
        columns: TransactionRowColumns,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [SplitTransactionRecord] {
        guard columns.hasParentID else { return [] }
        let order = columns.sortOrder.map { "\($0) DESC, id" } ?? "id"
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM transactions
                WHERE parent_id = ? AND \(database.predicateForLiveRows(columns: columns.all))
                ORDER BY \(order)
                """,
            arguments: [parentID]
        )
        return try ids.compactMap { try loadTransactionRecord(id: $0, columns: columns, db: db) }
    }

    static func loadLiveParentFamilies(
        columns: TransactionRowColumns,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [SplitTransactionRecord] {
        guard let isParentColumn = columns.isParent else { return [] }
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM transactions
                WHERE IFNULL(\(isParentColumn), 0) = 1
                  AND \(database.predicateForLiveRows(columns: columns.all))
                """
        )
        return try ids.compactMap { id -> SplitTransactionRecord? in
            let family = try loadSplitFamily(containing: id, columns: columns, in: database, db: db)
            guard var parent = family.first else { return nil }
            parent.subtransactions = Array(family.dropFirst())
            return parent
        }
    }

    static func loadTransactionRecord(
        id: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> SplitTransactionRecord? {
        guard let row = try TransactionRowReader.row(id: id, db: db) else { return nil }
        let parentID = TransactionRowReader.parentID(in: row, columns: columns)
        let isParent: Bool
        if let isParentColumn = columns.isParent {
            isParent = SQLiteValueCoercion.lenientBool(row[isParentColumn])
        } else {
            isParent = false
        }
        let isChild = TransactionRowReader.effectiveIsChild(row: row, columns: columns, parentID: parentID)
        let dateValue = SQLiteValueCoercion.int(row, "date") ?? 0
        return SplitTransactionRecord(
            id: id,
            amount: SQLiteValueCoercion.int(row, "amount") ?? 0,
            account: SQLiteValueCoercion.nonEmptyString(row, columns.account),
            date: PackedDate.iso(dateValue),
            category: SQLiteValueCoercion.nonEmptyString(row, "category"),
            payee: SQLiteValueCoercion.nonEmptyString(row, columns.payee),
            notes: columns.hasNotes ? SQLiteValueCoercion.nonEmptyString(row, "notes") : nil,
            cleared: columns.hasCleared ? SQLiteValueCoercion.lenientBool(row["cleared"]) : nil,
            reconciled: columns.hasReconciled ? SQLiteValueCoercion.lenientBool(row["reconciled"]) : nil,
            startingBalance: columns.hasStartingBalance
                ? SQLiteValueCoercion.lenientBool(row["starting_balance_flag"]) : nil,
            sortOrder: columns.sortOrder.flatMap { SQLiteValueCoercion.number(row, $0) },
            isParent: isParent,
            isChild: isChild,
            parentID: isChild ? parentID : nil,
            transferID: columns.transferID.flatMap { SQLiteValueCoercion.nonEmptyString(row, $0) },
            error: columns.hasError ? SplitTransactionError.parse(row["error"]) : nil,
            deleted: columns.hasTombstone ? SQLiteValueCoercion.lenientBool(row["tombstone"]) : false
        )
    }

    /// Rejects split drafts whose child ids would collide. Explicit ids must be
    /// unique, must not be the parent, and must be either an existing child of
    /// this family (update in place) or absent from `transactions`. A foreign
    /// id would otherwise overwrite an unrelated row, and a duplicate id traps
    /// in `persistFamilyChange`'s `Dictionary(uniqueKeysWithValues:)`.
    static func validateSplitDraftIDs(
        _ splits: [TransactionSplitDraft],
        parentID: String,
        familyChildIDs: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        var seen = Set<String>()
        for id in splits.compactMap(\.id) {
            guard id != parentID, seen.insert(id).inserted else {
                throw LocalFirstError.invalidLocalWrite("invalid split child id")
            }
            if !familyChildIDs.contains(id),
               try database.rowExists(table: "transactions", rowID: id, db: db) {
                throw LocalFirstError.invalidLocalWrite("invalid split child id")
            }
        }
    }
}
