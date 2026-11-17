import Foundation
import GRDB

struct SchedulePostingTransferMetadata: Sendable {
    let notes: String?
    let cleared: Bool
    let scheduleID: String?
}

enum TransactionCreationSQL {
    /// Create and update require an explicitly selected payee to be live. Payees
    /// created in the same plan are never selected ids, so they are not checked.
    static func requireLivePayee(_ payeeID: String, in database: isolated BudgetDatabase) throws {
        try database.queue.read { db in
            if try database.tableExists("payees", db: db),
               try !database.liveRowExists(table: "payees", rowID: payeeID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing payee")
            }
        }
    }

    /// A batch passes `knownPayees` (the picker-ordered table, read once) so
    /// each unknown name does not reload the whole payee table.
    static func resolveOrCreatePayeeMessages(
        selectedPayeeID: String?,
        payeeName: String,
        knownPayees: [ActualPayee]? = nil,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> (payeeID: String, messages: [ActualSyncDecodedMessage]) {
        if let selectedPayeeID, !selectedPayeeID.isEmpty {
            return (selectedPayeeID, [])
        }

        let trimmedName = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing payee name")
        }

        if let existing = try (knownPayees ?? PayeeSQL.fetchPayees(in: database)).first(where: {
            $0.transferAccount == nil && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }), let id = existing.id, !id.isEmpty {
            return (id, [])
        }

        let payeeID = UUID().uuidString
        var messages: [ActualSyncDecodedMessage] = []
        try database.queue.read { db in
            _ = try database.requiredColumns(table: "payees", required: ["name"], db: db)
            messages.append(
                try builder.makeMessage(
                    dataset: "payees",
                    row: payeeID,
                    column: "name",
                    value: .string(trimmedName)
                )
            )

            if try database.tableExists("payee_mapping", db: db) {
                _ = try database.requiredColumns(table: "payee_mapping", required: ["targetId"], db: db)
                messages.append(
                    try builder.makeMessage(
                        dataset: "payee_mapping",
                        row: payeeID,
                        column: "targetId",
                        value: .string(payeeID)
                    )
                )
            }
        }
        return (payeeID, messages)
    }

    static func createSimpleTransactionMessages(
        _ draft: TransactionDraft,
        transactionID: String,
        payeeID: String?,
        allowsZeroAmount: Bool = false,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            try createSimpleTransactionMessages(
                draft,
                transactionID: transactionID,
                payeeID: payeeID,
                allowsZeroAmount: allowsZeroAmount,
                builder: &builder,
                in: database,
                db: db
            )
        }
    }

    static func createSimpleTransactionMessages(
        _ draft: TransactionDraft,
        transactionID: String,
        payeeID: String?,
        allowsZeroAmount: Bool = false,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        try TransactionEditSQL.validateSimpleTransactionDraft(draft, allowsZeroAmount: allowsZeroAmount)
        if try database.tableExists("accounts", db: db),
           try !database.liveRowExists(table: "accounts", rowID: draft.accountID, db: db) {
            throw LocalFirstError.referencedRowUnavailable("missing account")
        }
        if let categoryID = draft.categoryID,
           try database.tableExists("categories", db: db),
           try !database.liveRowExists(table: "categories", rowID: categoryID, db: db) {
            throw LocalFirstError.referencedRowUnavailable("missing category")
        }
        let columns = try database.requiredColumns(
            table: "transactions",
            required: ["date", "amount"],
            db: db
        )
        let accountColumn = try database.firstExistingColumn(TransactionRowColumns.accountAliases, in: columns, table: "transactions")
        let payeeColumn = try database.firstExistingColumn(TransactionRowColumns.payeeAliases, in: columns, table: "transactions")
        let dateValue = try BudgetDatabase.actualDateValue(draft.date)

        // Actual's insert sends only the cells it sets: an absent payee, category or notes stays
        // unwritten, and structural columns (tombstone, isParent, parent_id) keep their defaults.
        var cells: [(column: String, value: LocalFirstSyncValue)] = [
            (accountColumn, .string(draft.accountID)),
            ("date", .int(Int64(dateValue))),
            ("amount", .int(Int64(draft.amountMinorUnits)))
        ]
        if let payeeID {
            cells.append((payeeColumn, .string(payeeID)))
        }
        if let categoryID = draft.categoryID {
            cells.append(("category", .string(categoryID)))
        }
        if columns.contains("notes"), let notes = draft.notes {
            cells.append(("notes", .string(notes)))
        }
        if columns.contains("cleared") {
            cells.append(("cleared", .bool(draft.cleared)))
        }
        if let importedPayee = draft.importedPayee,
           let importedPayeeColumn = TransactionRowColumns.importedPayee(in: columns) {
            cells.append((importedPayeeColumn, .string(importedPayee)))
        }
        if let importedID = draft.importedID, !importedID.isEmpty {
            let importedIDColumn = try database.firstExistingColumn(
                TransactionRowColumns.importedIDAliases,
                in: columns,
                table: "transactions"
            )
            cells.append((importedIDColumn, .string(importedID)))
        }
        if columns.contains("sort_order") {
            cells.append(("sort_order", .double(draft.sortOrder ?? Self.newRowSortOrder)))
        }
        if let scheduleID = draft.scheduleID, columns.contains("schedule") {
            cells.append(("schedule", .string(scheduleID)))
        }
        if columns.contains("reconciled") {
            cells.append(("reconciled", .bool(false)))
        }
        return try cells.map {
            try builder.makeMessage(dataset: "transactions", row: transactionID, column: $0.column, value: $0.value)
        }
    }

    /// Actual stamps a new row's `sort_order` with the clock in milliseconds.
    private static var newRowSortOrder: Double {
        Date().timeIntervalSince1970 * 1_000
    }

    static func createTransferTransactionMessages(
        draft: TransactionDraft,
        sourceTransactionID: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> (messages: [ActualSyncDecodedMessage], destinationAccountID: String, pairedTransactionID: String) {
        try database.queue.read { db in
            try createTransferTransactionMessages(
                draft: draft,
                sourceTransactionID: sourceTransactionID,
                payeeID: payeeID,
                builder: &builder,
                in: database,
                db: db
            )
        }
    }

    static func createTransferTransactionMessages(
        draft: TransactionDraft,
        sourceTransactionID: String,
        payeeID: String,
        schedulePostingMetadata: SchedulePostingTransferMetadata? = nil,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (messages: [ActualSyncDecodedMessage], destinationAccountID: String, pairedTransactionID: String) {
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.referencedRowUnavailable("missing account")
        }
        guard draft.amountMinorUnits != 0 else {
            throw LocalFirstError.invalidLocalWrite("missing amount")
        }

            let columns = try TransactionRowColumns.resolve(in: database, db: db)
            guard columns.transferID != nil else {
                throw LocalFirstError.schemaUnavailable("missing column transactions.transferred_id")
            }
            if try database.tableExists("accounts", db: db),
               try !database.liveRowExists(table: "accounts", rowID: draft.accountID, db: db) {
                throw LocalFirstError.referencedRowUnavailable("missing account")
            }
            let destinationAccountID = try TransferSQL.transferDestinationAccountID(payeeID: payeeID, in: database, db: db)
            let fromPayeeID = try TransferSQL.transferPayeeID(forAccount: draft.accountID, in: database, db: db)
            let dateValue = try BudgetDatabase.actualDateValue(draft.date)
            let pairedTransactionID = UUID().uuidString
            let sortOrder = draft.sortOrder ?? Self.newRowSortOrder
            // Actual clears the source category of a transfer between accounts on the same side
            // of the budget; crossing sides leaves an unassigned category unwritten.
            let sameSide = try AccountSQL.accountOffBudget(draft.accountID, in: database, db: db)
                == AccountSQL.accountOffBudget(destinationAccountID, in: database, db: db)
            // Only the budget side of a cross-budget transfer carries a category.
            let transferCategories = try TransferSQL.transferCategories(
                draft: draft,
                sourceAccountID: draft.accountID,
                destinationAccountID: destinationAccountID,
                in: database,
                db: db
            )

            let sourceMessages = try columns.rowMessages(
                rowID: sourceTransactionID,
                accountID: draft.accountID,
                dateValue: dateValue,
                amountMinorUnits: draft.amountMinorUnits,
                payeeID: payeeID,
                categoryID: transferCategories.source,
                notes: draft.notes,
                cleared: draft.cleared,
                isParent: false,
                parentID: nil,
                isChild: false,
                transferID: pairedTransactionID,
                sortOrder: sortOrder,
                builder: &builder,
                scheduleID: schedulePostingMetadata?.scheduleID ?? draft.scheduleID,
                cells: .inserted(clearsCategory: sameSide)
            )
            let pairedMessages = try columns.rowMessages(
                rowID: pairedTransactionID,
                accountID: destinationAccountID,
                dateValue: dateValue,
                amountMinorUnits: -draft.amountMinorUnits,
                payeeID: fromPayeeID,
                categoryID: transferCategories.destination,
                notes: schedulePostingMetadata.map(\.notes) ?? draft.counterpartNotes,
                cleared: schedulePostingMetadata?.cleared ?? false,
                isParent: false,
                parentID: nil,
                isChild: false,
                transferID: sourceTransactionID,
                sortOrder: sortOrder,
                builder: &builder,
                scheduleID: schedulePostingMetadata?.scheduleID
            )
        return (sourceMessages + pairedMessages, destinationAccountID, pairedTransactionID)
    }

    static func makeImportedIdentityMessages(
        transactionID: String,
        importedID: String?,
        importedPayee: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            let columns = try database.columnSet(for: "transactions", db: db)
            var messages: [ActualSyncDecodedMessage] = []
            if let importedPayee, !importedPayee.isEmpty,
               let importedPayeeColumn = TransactionRowColumns.importedPayee(in: columns) {
                messages.append(try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: importedPayeeColumn,
                    value: .string(importedPayee)
                ))
            }
            if let importedID, !importedID.isEmpty,
               let importedIDColumn = TransactionRowColumns.importedID(in: columns) {
                messages.append(try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: importedIDColumn,
                    value: .string(importedID)
                ))
            }
            return messages
        }
    }

    struct PlannedTransactionGraph {
        let write: BudgetDatabase.TransactionWriteResult
        let graph: BudgetTransactionGraph
        let primaryScheduleID: String?
        let primaryDate: Date
    }

    /// Produces a complete graph on the committing connection. Schedule posting
    /// uses this inside `commitLocalPlan` so graph validation and CRDT enqueue
    /// share the occurrence's atomic write transaction.
    static func schedulePostingTransactionGraph(
        draft: TransactionDraft,
        transactionID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> PlannedTransactionGraph {
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.referencedRowUnavailable("missing account")
        }
        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        guard columns.hasSchedule else {
            throw LocalFirstError.schemaUnavailable("transactions.schedule is unavailable")
        }
        if try database.tableExists("accounts", db: db),
           try !database.liveRowExists(table: "accounts", rowID: draft.accountID, db: db) {
            throw LocalFirstError.referencedRowUnavailable("missing account")
        }
        try validatePostingAccount(draft.accountID, in: database, db: db)

        if draft.isTransfer {
            guard let payeeID = draft.payeeID else {
                throw LocalFirstError.referencedRowUnavailable("missing transfer payee")
            }
            let destinationAccountID = try TransferSQL.transferDestinationAccountID(payeeID: payeeID, in: database, db: db)
            let destinationPayeeID = try TransferSQL.transferPayeeID(forAccount: draft.accountID, in: database, db: db)
            let destinationDraft = TransactionDraft(
                accountID: destinationAccountID,
                date: draft.date,
                amountMinorUnits: -draft.amountMinorUnits,
                payeeID: destinationPayeeID,
                payeeName: try RulePreviewSQL.rulePayeeName(for: destinationPayeeID, in: database, db: db) ?? "",
                categoryID: nil,
                notes: draft.counterpartNotes,
                cleared: false,
                isTransfer: true,
                scheduleID: draft.scheduleID
            )
            let pairedPreview = try RulePreviewSQL.previewRules(for: destinationDraft, in: database, db: db)
            let transferMetadata = SchedulePostingTransferMetadata(
                notes: pairedPreview.notes,
                cleared: pairedPreview.cleared ?? false,
                scheduleID: pairedPreview.scheduleID ?? draft.scheduleID
            )
            let transfer = try createTransferTransactionMessages(
                draft: draft,
                sourceTransactionID: transactionID,
                payeeID: payeeID,
                schedulePostingMetadata: transferMetadata,
                builder: &builder,
                in: database,
                db: db
            )
            try validatePostingAccount(transfer.destinationAccountID, in: database, db: db)
            return PlannedTransactionGraph(
                write: BudgetDatabase.TransactionWriteResult(
                    messages: transfer.messages,
                    affectedAccountIDs: [draft.accountID, transfer.destinationAccountID],
                    affectedTransactionIDs: [transactionID, transfer.pairedTransactionID]
                ),
                graph: .transfer(pairedID: transfer.pairedTransactionID),
                primaryScheduleID: transferMetadata.scheduleID,
                primaryDate: draft.date
            )
        }

        if draft.isSplit {
            let write = try createSplitFamilyWrite(
                draft: draft,
                parentTransactionID: transactionID,
                payeeID: draft.payeeID,
                builder: &builder,
                in: database,
                db: db
            )
            return PlannedTransactionGraph(
                write: write,
                graph: .split(childIDs: write.affectedTransactionIDs.filter { $0 != transactionID }),
                primaryScheduleID: draft.scheduleID,
                primaryDate: draft.date
            )
        }

        let messages = try createSimpleTransactionMessages(
            draft,
            transactionID: transactionID,
            payeeID: draft.payeeID,
            builder: &builder,
            in: database,
            db: db
        )
        return PlannedTransactionGraph(
            write: BudgetDatabase.TransactionWriteResult(
                messages: messages,
                affectedAccountIDs: [draft.accountID],
                affectedTransactionIDs: [transactionID]
            ),
            graph: .simple,
            primaryScheduleID: draft.scheduleID,
            primaryDate: draft.date
        )
    }

    static func createSplitFamilyWrite(
        draft: TransactionDraft,
        parentTransactionID: String,
        payeeID: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetDatabase.TransactionWriteResult {
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.referencedRowUnavailable("missing account")
        }
        guard !draft.splits.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("split requires at least one child")
        }
        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        if try database.tableExists("accounts", db: db),
           try !database.liveRowExists(table: "accounts", rowID: draft.accountID, db: db) {
            throw LocalFirstError.referencedRowUnavailable("missing account")
        }
        try SplitFamilySQL.validateSplitCategories(draft.splits, in: database, db: db)
        try SplitFamilySQL.validateSplitDraftIDs(
            draft.splits,
            parentID: parentTransactionID,
            familyChildIDs: [],
            in: database,
            db: db
        )
        let parent = try SplitFamilySQL.splitParentRecord(
            id: parentTransactionID,
            draft: draft,
            payeeID: payeeID,
            inheritFrom: nil
        )
        let family = SplitFamilySQL.materializeSplitFamily(
            parent: parent,
            drafts: draft.splits,
            existingChildren: [],
            nullParentPayee: true
        )
        let persisted = try SplitFamilySQL.persistFamilyChange(
            oldRows: [],
            newRows: SplitTransactionFamilyOps.ungroupTransaction(family),
            columns: columns,
            builder: &builder,
            in: database,
            db: db
        )
        return try SplitFamilySQL.appendingSplitParentImportMetadata(
            to: persisted,
            parentTransactionID: parentTransactionID,
            draft: draft,
            columns: columns,
            builder: &builder
        )
    }

    private static func validatePostingAccount(_ accountID: String, in database: isolated BudgetDatabase, db: Database) throws {
        let columns = try database.requiredColumns(table: "accounts", required: ["id"], db: db)
        let closed = database.column("closed", fallback: "0", columns: columns)
        let tombstone = database.column("tombstone", fallback: "0", columns: columns)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT \(closed) AS closed, \(tombstone) AS tombstone FROM accounts WHERE id = ? LIMIT 1",
            arguments: [accountID]
        ), !SQLiteValueCoercion.lenientBool(row["closed"]), !SQLiteValueCoercion.lenientBool(row["tombstone"]) else {
            throw LocalFirstError.referencedRowUnavailable("transaction account is closed or unavailable")
        }
    }

    /// A caller-chosen primary transaction id a create is about to insert.
    /// The commit transaction checks it live, because an earlier attempt of the
    /// same editor presentation may already have committed. A tombstoned row
    /// counts as present: a create retried after a delete must not resurrect it.
    struct TransactionIDAbsence: Sendable {
        let transactionID: String

        func isViolated(in database: isolated BudgetDatabase, db: Database) throws -> Bool {
            try database.rowExists(table: "transactions", rowID: transactionID, db: db)
        }
    }
}
