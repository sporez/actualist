import Foundation
import GRDB

struct SchedulePostingTransferMetadata: Sendable {
    let notes: String?
    let cleared: Bool
    let scheduleID: String?
}

extension BudgetDatabase {
    struct PlannedTransactionGraph {
        let write: TransactionWriteResult
        let graph: BudgetTransactionGraph
        let primaryScheduleID: String?
        let primaryDate: Date
    }

    /// Produces a complete graph on the committing connection. Schedule posting
    /// uses this inside `commitLocalPlan` so graph validation and CRDT enqueue
    /// share the occurrence's atomic write transaction.
    func schedulePostingTransactionGraph(
        draft: TransactionDraft,
        transactionID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        db: Database
    ) throws -> PlannedTransactionGraph {
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        let columns = try resolveTransactionRowColumns(db: db)
        guard columns.hasSchedule else {
            throw LocalFirstError.invalidLocalWrite("transactions.schedule is unavailable")
        }
        if try tableExists("accounts", db: db),
           try !liveRowExists(table: "accounts", rowID: draft.accountID, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        try validatePostingAccount(draft.accountID, db: db)

        if draft.isTransfer {
            guard let payeeID = draft.payeeID else {
                throw LocalFirstError.invalidLocalWrite("missing transfer payee")
            }
            let destinationAccountID = try transferDestinationAccountID(payeeID: payeeID, db: db)
            let destinationPayeeID = try transferPayeeID(forAccount: draft.accountID, db: db)
            let destinationDraft = TransactionDraft(
                accountID: destinationAccountID,
                date: draft.date,
                amountMinorUnits: -draft.amountMinorUnits,
                payeeID: destinationPayeeID,
                payeeName: try rulePayeeName(for: destinationPayeeID, db: db) ?? "",
                categoryID: nil,
                notes: draft.notes,
                cleared: false,
                isTransfer: true,
                scheduleID: draft.scheduleID
            )
            let pairedPreview = try previewRules(for: destinationDraft, db: db)
            let transferMetadata = SchedulePostingTransferMetadata(
                notes: pairedPreview.notes,
                cleared: pairedPreview.cleared ?? false,
                scheduleID: pairedPreview.scheduleID ?? draft.scheduleID
            )
            let transfer = try createTransferTransactionMessages(
                draft: draft,
                sourceTransactionID: transactionID,
                payeeID: payeeID,
                db: db,
                schedulePostingMetadata: transferMetadata,
                builder: &builder
            )
            try validatePostingAccount(transfer.destinationAccountID, db: db)
            return PlannedTransactionGraph(
                write: TransactionWriteResult(
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
                db: db,
                builder: &builder
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
            db: db,
            builder: &builder
        )
        return PlannedTransactionGraph(
            write: TransactionWriteResult(
                messages: messages,
                affectedAccountIDs: [draft.accountID],
                affectedTransactionIDs: [transactionID]
            ),
            graph: .simple,
            primaryScheduleID: draft.scheduleID,
            primaryDate: draft.date
        )
    }

    func createSplitFamilyWrite(
        draft: TransactionDraft,
        parentTransactionID: String,
        payeeID: String?,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard !draft.splits.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("split requires at least one child")
        }
        let columns = try resolveTransactionRowColumns(db: db)
        if try tableExists("accounts", db: db),
           try !liveRowExists(table: "accounts", rowID: draft.accountID, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        try validateSplitCategories(draft.splits, db: db)
        try validateSplitDraftIDs(
            draft.splits,
            parentID: parentTransactionID,
            familyChildIDs: [],
            db: db
        )
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
        let persisted = try persistFamilyChange(
            oldRows: [],
            newRows: SplitTransactionFamilyOps.ungroupTransaction(family),
            columns: columns,
            db: db,
            builder: &builder
        )
        return try appendingSplitParentImportMetadata(
            to: persisted,
            parentTransactionID: parentTransactionID,
            draft: draft,
            columns: columns,
            builder: &builder
        )
    }

    private func validatePostingAccount(_ accountID: String, db: Database) throws {
        let columns = try requiredColumns(table: "accounts", required: ["id"], db: db)
        let closed = column("closed", fallback: "0", columns: columns)
        let tombstone = column("tombstone", fallback: "0", columns: columns)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT \(closed) AS closed, \(tombstone) AS tombstone FROM accounts WHERE id = ? LIMIT 1",
            arguments: [accountID]
        ), !flexibleBool(row["closed"]), !flexibleBool(row["tombstone"]) else {
            throw LocalFirstError.invalidLocalWrite("transaction account is closed or unavailable")
        }
    }
}
