import Foundation
import GRDB

/// Per-plan view of the split families a batch delete touches.
///
/// Selections are applied one after another, so each one must see the
/// families as the previous selections left them. Re-reading SQLite would
/// return the pre-batch state and either re-delete rows or skip selected ones.
/// `tombstoned` is the authoritative set of rows this plan actually deletes;
/// a selection already in it is covered by an earlier one.
struct BatchDeleteOverlay {
    private var families: [String: [SplitTransactionRecord]] = [:]
    private var rootByRow: [String: String] = [:]
    private(set) var tombstoned: Set<String> = []

    func isLoaded(_ id: String) -> Bool { rootByRow[id] != nil }

    func family(containing id: String) -> [SplitTransactionRecord]? {
        rootByRow[id].flatMap { families[$0] }
    }

    func record(_ id: String) -> SplitTransactionRecord? {
        family(containing: id)?.first { $0.id == id }
    }

    mutating func load(_ family: [SplitTransactionRecord]) {
        guard let root = family.first?.id else { return }
        families[root] = family
        for row in family { rootByRow[row.id] = root }
    }

    mutating func replaceFamily(root: String, with rows: [SplitTransactionRecord]) {
        for (id, rowRoot) in rootByRow where rowRoot == root { rootByRow[id] = nil }
        families[root] = rows.isEmpty ? nil : rows
        for row in rows { rootByRow[row.id] = root }
    }

    mutating func markTombstoned(_ id: String) {
        tombstoned.insert(id)
        guard let root = rootByRow[id], var family = families[root] else { return }
        family.removeAll { $0.id == id }
        replaceFamily(root: root, with: family)
    }

    mutating func clearTransferLink(of id: String) {
        guard let root = rootByRow[id], var family = families[root],
              let index = family.firstIndex(where: { $0.id == id }) else { return }
        family[index].transferID = nil
        family[index].payee = nil
        families[root] = family
    }
}

struct PlainTransactionDeletePair {
    let id: String
    let accountID: String?
    let isChild: Bool
}

extension BudgetDatabase {
    /// Deletes a plain (non-split) row. A transfer counterpart that is a split
    /// child only loses its link and payee; any other counterpart is deleted.
    /// Shared by single delete and batch delete.
    func plainTransactionDeleteWrite(
        transactionID: String,
        accountID: String?,
        pair: PlainTransactionDeletePair?,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        var messages = [try tombstoneMessage(rowID: transactionID, builder: &builder)]
        var affectedIDs: Set<String> = [transactionID]
        var affectedAccounts = Set([accountID].compactMap { $0 })
        if let pair {
            affectedIDs.insert(pair.id)
            if let account = pair.accountID { affectedAccounts.insert(account) }
            if pair.isChild, let transferColumn = columns.transferID {
                messages.append(try builder.makeMessage(dataset: "transactions", row: pair.id, column: transferColumn, value: .null))
                messages.append(try builder.makeMessage(dataset: "transactions", row: pair.id, column: columns.payee, value: .null))
            } else {
                messages.append(try tombstoneMessage(rowID: pair.id, builder: &builder))
            }
        }
        return TransactionWriteResult(
            messages: messages,
            affectedAccountIDs: Array(affectedAccounts),
            affectedTransactionIDs: Array(affectedIDs)
        )
    }

    /// Messages for one selected row, given the batch's earlier deletions.
    /// Returns no messages when an earlier selection already tombstoned it.
    func batchDeleteWrite(
        transactionID: String,
        overlay: inout BatchDeleteOverlay,
        columns: TransactionRowColumns,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        if overlay.tombstoned.contains(transactionID) {
            return TransactionWriteResult(messages: [], affectedAccountIDs: [], affectedTransactionIDs: [])
        }
        guard try loadBatchDeleteFamily(containing: transactionID, overlay: &overlay, columns: columns, db: db),
              let record = overlay.record(transactionID),
              let family = overlay.family(containing: transactionID) else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        let write: TransactionWriteResult
        if record.isParent || record.isChild {
            let result = SplitTransactionFamilyOps.deleteTransaction(family, id: transactionID)
            write = try persistFamilyChange(
                oldRows: family,
                newRows: result.data,
                columns: columns,
                db: db,
                builder: &builder
            )
            overlay.replaceFamily(root: family[0].id, with: result.data)
        } else {
            var pair: PlainTransactionDeletePair?
            if let pairedID = record.transferID,
               try loadBatchDeleteFamily(containing: pairedID, overlay: &overlay, columns: columns, db: db),
               let paired = overlay.record(pairedID) {
                pair = PlainTransactionDeletePair(id: pairedID, accountID: paired.account, isChild: paired.isChild)
            }
            write = try plainTransactionDeleteWrite(
                transactionID: transactionID,
                accountID: record.account,
                pair: pair,
                columns: columns,
                builder: &builder
            )
        }
        try absorbBatchDeleteMessages(write.messages, overlay: &overlay, columns: columns, db: db)
        return write
    }

    /// Loads the family from SQLite unless an earlier selection already did.
    /// Returns false for a missing or already tombstoned row.
    private func loadBatchDeleteFamily(
        containing id: String,
        overlay: inout BatchDeleteOverlay,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> Bool {
        if overlay.isLoaded(id) { return true }
        guard !overlay.tombstoned.contains(id),
              try transactionBatchSnapshot(id: id, columns: columns, db: db)?.tombstone != true else { return false }
        let family = try loadSplitFamily(containing: id, columns: columns, db: db)
        guard !family.isEmpty else { return false }
        overlay.load(family)
        return overlay.isLoaded(id)
    }

    /// Reflects a write's side effects on rows outside the deleted family
    /// (tombstoned counterparts, split children that lose their transfer link).
    private func absorbBatchDeleteMessages(
        _ messages: [ActualSyncDecodedMessage],
        overlay: inout BatchDeleteOverlay,
        columns: TransactionRowColumns,
        db: Database
    ) throws {
        for message in messages {
            let value = try deserializeSyncValue(message.serializedValue)
            if message.column == "tombstone", case .int(1) = value {
                overlay.markTombstoned(message.row)
            } else if !overlay.tombstoned.contains(message.row),
                      message.column == columns.transferID || message.column == columns.payee,
                      case .null = value {
                _ = try loadBatchDeleteFamily(containing: message.row, overlay: &overlay, columns: columns, db: db)
                if message.column == columns.transferID { overlay.clearTransferLink(of: message.row) }
            }
        }
    }
}
