import Foundation
import GRDB

extension BudgetDatabase {

    func splitErrorValue(_ error: SplitTransactionError?) -> LocalFirstSyncValue {
        guard let error else { return .null }
        return .string(
            "{\"type\":\"\(error.type)\",\"version\":\(error.version),\"difference\":\(error.difference)}"
        )
    }

    func createSplitTransactionMessages(
        draft: TransactionDraft,
        parentTransactionID: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try createSplitFamilyWrite(
            draft: draft,
            parentTransactionID: parentTransactionID,
            payeeID: payeeID,
            builder: &builder
        ).messages
    }

    func createSplitFamilyWrite(
        draft: TransactionDraft,
        parentTransactionID: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard !draft.splits.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("split requires at least one child")
        }

        return try queue.read { db in
            let columns = try resolveTransactionRowColumns(db: db)
            if try tableExists("accounts", db: db),
               try !rowExists(table: "accounts", rowID: draft.accountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing account")
            }
            try validateSplitCategories(draft.splits, db: db)
            let parent = try splitParentRecord(
                id: parentTransactionID,
                draft: draft,
                payeeID: payeeID,
                inheritFrom: nil
            )
            let family = materializeSplitFamily(
                parent: parent,
                drafts: draft.splits,
                existingChildren: [],
                nullParentPayee: true
            )
            return try persistFamilyChange(
                oldRows: [],
                newRows: SplitTransactionFamilyOps.ungroupTransaction(family),
                columns: columns,
                db: db,
                builder: &builder
            )
        }
    }

    func splitFamilyUpdateMessages(
        transactionID: String,
        draft: TransactionDraft,
        payeeID: String,
        columns: TransactionRowColumns,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        try validateSplitCategories(draft.splits, db: db)
        let oldRows = try loadSplitFamily(containing: transactionID, columns: columns, db: db)
        guard let current = oldRows.first(where: { $0.id == transactionID }) ?? oldRows.first else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }

        if current.isChild && !draft.isSplit {
            var child = current
            child.amount = draft.amountMinorUnits
            child.category = draft.categoryID
            child.payee = payeeID
            child.notes = draft.notes
            child.cleared = draft.cleared
            child.reconciled = draft.reconciled
            let result = SplitTransactionFamilyOps.updateTransaction(oldRows, transaction: child)
            return try persistFamilyChange(
                oldRows: oldRows,
                newRows: result.data,
                columns: columns,
                db: db,
                builder: &builder
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
                db: db,
                builder: &builder
            )
        }

        let converting = !current.isParent && !current.isChild
        var parent = try splitParentRecord(
            id: current.isChild ? (current.parentID ?? current.id) : current.id,
            draft: draft,
            payeeID: payeeID,
            inheritFrom: oldRows.first(where: \.isParent) ?? current
        )
        parent.payee = payeeID
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
            db: db,
            builder: &builder
        )
    }

    func deleteSplitFamilyMessages(
        transactionID: String,
        columns: TransactionRowColumns,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        let oldRows = try loadSplitFamily(containing: transactionID, columns: columns, db: db)
        guard !oldRows.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        let result = SplitTransactionFamilyOps.deleteTransaction(oldRows, id: transactionID)
        return try persistFamilyChange(
            oldRows: oldRows,
            newRows: result.data,
            columns: columns,
            db: db,
            builder: &builder
        )
    }

    func materializeSplitFamily(
        parent: SplitTransactionRecord,
        drafts: [TransactionSplitDraft],
        existingChildren: [SplitTransactionRecord],
        nullParentPayee: Bool
    ) -> SplitTransactionRecord {
        let children = drafts.enumerated().map { index, draft in
            SplitTransactionFamilyOps.makeChild(
                parent: parent,
                data: childPatch(draft, existing: existingChildren, index: index)
            )
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

    func childPatch(
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

    func splitParentRecord(
        id: String,
        draft: TransactionDraft,
        payeeID: String,
        inheritFrom: SplitTransactionRecord?
    ) throws -> SplitTransactionRecord {
        let dateValue = try Self.actualDateValue(draft.date)
        return SplitTransactionRecord(
            id: id,
            amount: draft.amountMinorUnits,
            account: draft.accountID,
            date: Self.isoDateString(fromPacked: dateValue),
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

    func validateSplitCategories(_ splits: [TransactionSplitDraft], db: Database) throws {
        guard try tableExists("categories", db: db) else { return }
        for split in splits {
            if let categoryID = split.categoryID,
               try !rowExists(table: "categories", rowID: categoryID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
        }
    }

    func persistFamilyChange(
        oldRows: [SplitTransactionRecord],
        newRows: [SplitTransactionRecord],
        columns: TransactionRowColumns,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
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
            let prepared = try prepareTransferOnInsert(
                row,
                columns: columns,
                affectedAccounts: &affectedAccounts,
                affectedTransactions: &affectedTransactions,
                db: db,
                builder: &builder
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
            let transfer = try transferMessagesOnUpdate(
                old: old,
                new: new,
                columns: columns,
                db: db,
                builder: &builder
            )
            messages += transfer.messages
            affectedAccounts.formUnion(transfer.accounts)
            affectedTransactions.formUnion(transfer.transactions)
        }

        for id in deletedIDs.sorted() {
            guard let old = oldByID[id] else { continue }
            if columns.hasTombstone {
                messages.append(try tombstoneMessage(rowID: id, builder: &builder))
            }
            let transfer = try transferMessagesOnDelete(
                old,
                columns: columns,
                db: db,
                builder: &builder
            )
            messages += transfer.messages
            affectedAccounts.formUnion(transfer.accounts)
            affectedTransactions.formUnion(transfer.transactions)
        }

        return TransactionWriteResult(
            messages: messages,
            affectedAccountIDs: Array(affectedAccounts),
            affectedTransactionIDs: Array(affectedTransactions)
        )
    }

    func messagesForNewRow(
        _ row: SplitTransactionRecord,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try transactionRowMessages(
            rowID: row.id,
            accountID: row.account ?? "",
            dateValue: Self.packedDate(fromISO: row.date),
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
            columns: columns,
            builder: &builder
        )
    }

    func messagesForChangedFields(
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
            fields.append(("date", .int(Int64(Self.packedDate(fromISO: new.date)))))
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
        if columns.hasNotes, old.notes != new.notes {
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
            fields.append(("error", splitErrorValue(new.isParent ? new.error : nil)))
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

    func prepareTransferOnInsert(
        _ row: SplitTransactionRecord,
        columns: TransactionRowColumns,
        affectedAccounts: inout Set<String>,
        affectedTransactions: inout Set<String>,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (row: SplitTransactionRecord, messages: [ActualSyncDecodedMessage]) {
        guard !row.isParent,
              let destination = try transferAccountID(ifPayee: row.payee, db: db),
              columns.transferID != nil,
              let account = row.account else {
            return (row, [])
        }
        let pairedID = UUID().uuidString
        let fromPayeeID = try transferPayeeID(forAccount: account, db: db)
        let clearCategory = try accountOffBudget(account, db: db) == accountOffBudget(destination, db: db)
        var next = row
        next.transferID = pairedID
        if clearCategory {
            next.category = nil
        }
        affectedAccounts.insert(destination)
        affectedTransactions.insert(pairedID)
        let paired = try transactionRowMessages(
            rowID: pairedID,
            accountID: destination,
            dateValue: Self.packedDate(fromISO: row.date),
            amountMinorUnits: -row.amount,
            payeeID: fromPayeeID,
            categoryID: nil,
            notes: row.notes,
            cleared: false,
            isParent: false,
            parentID: nil,
            isChild: false,
            transferID: row.id,
            sortOrder: nil,
            columns: columns,
            builder: &builder
        )
        return (next, paired)
    }

    func transferMessagesOnUpdate(
        old: SplitTransactionRecord,
        new: SplitTransactionRecord,
        columns: TransactionRowColumns,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (messages: [ActualSyncDecodedMessage], accounts: Set<String>, transactions: Set<String>) {
        if new.isParent {
            return try transferMessagesOnDelete(old, columns: columns, db: db, builder: &builder)
        }
        let destination = try transferAccountID(ifPayee: new.payee, db: db)
        if let destination, new.transferID == nil {
            var accounts: Set<String> = []
            var transactions: Set<String> = []
            let prepared = try prepareTransferOnInsert(
                new,
                columns: columns,
                affectedAccounts: &accounts,
                affectedTransactions: &transactions,
                db: db,
                builder: &builder
            )
            var messages = prepared.messages
            if let transferColumn = columns.transferID, let transferID = prepared.row.transferID {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: new.id,
                        column: transferColumn,
                        value: .string(transferID)
                    )
                )
            }
            if prepared.row.category == nil, old.category != nil {
                messages.append(
                    try builder.makeMessage(dataset: "transactions", row: new.id, column: "category", value: .null)
                )
            }
            return (messages, accounts, transactions)
        }
        if destination == nil, let pairedID = old.transferID {
            return try transferMessagesOnDelete(old, columns: columns, db: db, builder: &builder)
        }
        guard let destination, let pairedID = new.transferID ?? old.transferID, let account = new.account else {
            return ([], [], [])
        }
        let fromPayeeID = try transferPayeeID(forAccount: account, db: db)
        var messages: [ActualSyncDecodedMessage] = []
        messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.account, value: .string(destination)))
        messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .string(fromPayeeID)))
        if columns.hasNotes {
            messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "notes", value: new.notes.map(LocalFirstSyncValue.string) ?? .null))
        }
        messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "amount", value: .int(Int64(-new.amount))))
        if try accountOffBudget(account, db: db) == accountOffBudget(destination, db: db) {
            messages.append(try builder.makeMessage(dataset: "transactions", row: new.id, column: "category", value: .null))
            messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "category", value: .null))
        }
        return (messages, [destination], [pairedID])
    }

    func transferMessagesOnDelete(
        _ old: SplitTransactionRecord,
        columns: TransactionRowColumns,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (messages: [ActualSyncDecodedMessage], accounts: Set<String>, transactions: Set<String>) {
        guard let pairedID = old.transferID, let transferColumn = columns.transferID else {
            return ([], [], [])
        }
        var messages: [ActualSyncDecodedMessage] = []
        var accounts: Set<String> = []
        if let paired = try loadTransactionRecord(id: pairedID, columns: columns, db: db) {
            if let account = paired.account {
                accounts.insert(account)
            }
            if paired.isChild {
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: transferColumn, value: .null))
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .null))
            } else if columns.hasTombstone {
                messages.append(try tombstoneMessage(rowID: pairedID, builder: &builder))
            }
        }
        if !old.deleted {
            messages.append(try builder.makeMessage(dataset: "transactions", row: old.id, column: transferColumn, value: .null))
        }
        return (messages, accounts, [pairedID])
    }

    func transferAccountID(ifPayee payeeID: String?, db: Database) throws -> String? {
        guard let payeeID, !payeeID.isEmpty, try tableExists("payees", db: db) else {
            return nil
        }
        let payeeColumns = try columnSet(for: "payees", db: db)
        let transferColumn = column(
            "transfer_acct",
            fallback: column("transferAccount", fallback: "NULL", columns: payeeColumns),
            columns: payeeColumns
        )
        guard transferColumn != "NULL" else { return nil }
        return try String.fetchOne(
            db,
            sql: "SELECT \(transferColumn) FROM payees WHERE id = ?",
            arguments: [payeeID]
        ).flatMap { $0.isEmpty ? nil : $0 }
    }

    func loadSplitFamily(
        containing id: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> [SplitTransactionRecord] {
        guard let current = try loadTransactionRecord(id: id, columns: columns, db: db) else {
            return []
        }
        let parentID = current.isChild ? (current.parentID ?? id) : id
        guard let parent = try loadTransactionRecord(id: parentID, columns: columns, db: db) else {
            return [current]
        }
        let children = try loadChildRecords(parentID: parent.id, columns: columns, db: db)
        var parentRow = parent
        parentRow.subtransactions = []
        return [parentRow] + children
    }

    func loadChildRecords(
        parentID: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> [SplitTransactionRecord] {
        guard columns.hasParentID else { return [] }
        let order = columns.sortOrder.map { "\($0) DESC, id" } ?? "id"
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM transactions
                WHERE parent_id = ? AND \(predicateForLiveRows(columns: columns.all))
                ORDER BY \(order)
                """,
            arguments: [parentID]
        )
        return try ids.compactMap { try loadTransactionRecord(id: $0, columns: columns, db: db) }
    }

    func loadLiveParentFamilies(
        columns: TransactionRowColumns,
        db: Database
    ) throws -> [SplitTransactionRecord] {
        guard let isParentColumn = columns.isParent else { return [] }
        let ids = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM transactions
                WHERE IFNULL(\(isParentColumn), 0) = 1
                  AND \(predicateForLiveRows(columns: columns.all))
                """
        )
        return try ids.compactMap { id -> SplitTransactionRecord? in
            let family = try loadSplitFamily(containing: id, columns: columns, db: db)
            guard var parent = family.first else { return nil }
            parent.subtransactions = Array(family.dropFirst())
            return parent
        }
    }

    func loadTransactionRecord(
        id: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> SplitTransactionRecord? {
        guard try rowExists(table: "transactions", rowID: id, db: db) else {
            return nil
        }
        let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM transactions WHERE id = ?",
            arguments: [id]
        )
        guard let row else { return nil }
        let parentID = columns.hasParentID
            ? (row["parent_id"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            : nil
        let isParent: Bool
        if let isParentColumn = columns.isParent {
            isParent = flexibleBool(row[isParentColumn])
        } else {
            isParent = false
        }
        let isChild = effectiveIsChild(row: row, columns: columns, parentID: parentID)
        let dateValue: Int = row["date"] ?? 0
        return SplitTransactionRecord(
            id: id,
            amount: row["amount"] ?? 0,
            account: (row[columns.account] as String?).flatMap { $0.isEmpty ? nil : $0 },
            date: Self.isoDateString(fromPacked: dateValue),
            category: (row["category"] as String?).flatMap { $0.isEmpty ? nil : $0 },
            payee: (row[columns.payee] as String?).flatMap { $0.isEmpty ? nil : $0 },
            notes: columns.hasNotes ? (row["notes"] as String?).flatMap { $0.isEmpty ? nil : $0 } : nil,
            cleared: columns.hasCleared ? flexibleBool(row["cleared"]) : nil,
            reconciled: columns.hasReconciled ? flexibleBool(row["reconciled"]) : nil,
            startingBalance: columns.hasStartingBalance ? flexibleBool(row["starting_balance_flag"]) : nil,
            sortOrder: columns.sortOrder.flatMap { column in
                if let value = row[column] as Double? { return value }
                if let value = row[column] as Int? { return Double(value) }
                return nil
            },
            isParent: isParent,
            isChild: isChild,
            parentID: isChild ? parentID : nil,
            transferID: columns.transferID.flatMap { column in
                (row[column] as String?).flatMap { $0.isEmpty ? nil : $0 }
            },
            error: columns.hasError ? parseSplitTransactionError(row["error"]) : nil,
            deleted: columns.hasTombstone ? flexibleBool(row["tombstone"]) : false
        )
    }

    func effectiveIsChild(row: Row, columns: TransactionRowColumns, parentID: String?) -> Bool {
        guard let isChildColumn = columns.isChild else {
            return parentID != nil
        }
        let value: Int? = row[isChildColumn]
        if value == nil {
            return parentID != nil
        }
        return value != 0
    }

    static func isoDateString(fromPacked packed: Int) -> String {
        String(format: "%04d-%02d-%02d", packed / 10_000, (packed / 100) % 100, packed % 100)
    }

    static func packedDate(fromISO date: String?) -> Int {
        Int((date ?? "").replacingOccurrences(of: "-", with: "")) ?? 0
    }
}
