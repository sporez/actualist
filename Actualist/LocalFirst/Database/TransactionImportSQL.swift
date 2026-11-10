import Foundation
import GRDB

/// File-import reads and checks that run inside `BudgetDatabase`'s write
/// transaction. Stateless: the actor stays the single owner of the queue,
/// clock, merkle state and write fence, and lends its schema helpers through
/// the `isolated` parameter.
enum TransactionImportSQL {
    /// One matched row decided at review time, with its file line for error
    /// reporting. `existing` is the stored row as the review saw it.
    struct Match: Sendable {
        let line: Int
        let update: BankSyncReconciliation.MatchedUpdate
        let existing: BankSyncReconciliation.Existing
    }

    /// Categories in the order of the list Actual's import modal matches
    /// against (`useCategories().list`): live groups ordered by `is_income,
    /// sort_order, id` (the AQL default for `category_groups`), each group's
    /// live categories by `sort_order, id`, flattened. A category whose group
    /// is missing or deleted is not in that list.
    static func categoryList(
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ImportCategoryMatcher.Category] {
        guard try database.tableExists("categories", db: db),
              try database.tableExists("category_groups", db: db) else {
            return []
        }
        let categoryColumns = try database.columnSet(for: "categories", db: db)
        let groupColumns = try database.columnSet(for: "category_groups", db: db)
        guard let groupColumn = ["cat_group", "group_id"].first(where: categoryColumns.contains) else {
            return []
        }
        func order(_ alias: String, _ column: String, in columns: Set<String>) -> String {
            columns.contains(column) ? "\(alias).\(column)" : "NULL"
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id, c.name AS name
                FROM categories c
                JOIN category_groups g ON g.id = c.\(groupColumn)
                WHERE \(database.predicateForLiveRows(columns: categoryColumns, tableAlias: "c"))
                  AND \(database.predicateForLiveRows(columns: groupColumns, tableAlias: "g"))
                ORDER BY \(order("g", "is_income", in: groupColumns)), \(order("g", "sort_order", in: groupColumns)), g.id,
                         \(order("c", "sort_order", in: categoryColumns)), c.id
                """
        )
        return rows.compactMap { row in
            guard let id: String = row["id"], !id.isEmpty else { return nil }
            return ImportCategoryMatcher.Category(id: id, name: row["name"] ?? "")
        }
    }

    /// The live synced preferences among `keys`, as Actual stores them.
    static func preferences(
        keys: [String],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        for key in keys {
            values[key] = try database.preferenceValue(key, db: db)
        }
        return values
    }

    /// Re-checks every reviewed match against the live rows.
    static func validateMatches(
        _ matches: [Match],
        accountID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let columns = try database.columnSet(for: "transactions", db: db)
        for match in matches {
            try validateMatch(match, accountID: accountID, columns: columns, in: database, db: db)
        }
    }

    /// The row must still be live, in the importing account and not
    /// reconciled, its `imported_id` must be unchanged, and every field the
    /// update fills must still hold the value the review saw (the fill
    /// semantics the review showed).
    private static func validateMatch(
        _ match: Match,
        accountID: String,
        columns: Set<String>,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let changed = TransactionCSVImportError.matchChanged(line: match.line)
        let update = match.update
        let existing = match.existing
        let accountColumn = ["acct", "account"].first(where: columns.contains)
        let payeeColumn = ["description", "payee"].first(where: columns.contains)
        let importedIDColumn = ["financial_id", "imported_id"].first(where: columns.contains)
        guard let accountColumn,
              let live = try Row.fetchOne(
                  db,
                  sql: """
                      SELECT \(accountColumn) AS account,
                             \(importedIDColumn ?? "NULL") AS imported_id,
                             \(payeeColumn ?? "NULL") AS payee,
                             \(columns.contains("category") ? "category" : "NULL") AS category,
                             \(columns.contains("notes") ? "notes" : "NULL") AS notes,
                             \(columns.contains("cleared") ? "cleared" : "NULL") AS cleared,
                             \(columns.contains("reconciled") ? "reconciled" : "NULL") AS reconciled
                      FROM transactions
                      WHERE id = ? AND \(database.predicateForLiveRows(columns: columns))
                      """,
                  arguments: [update.existingID]
              ),
              (live["account"] as String?) == accountID,
              !database.flexibleBool(live["reconciled"]) else {
            throw changed
        }
        // Checked even when the update does not write it: under strict id
        // checking the stored id decides whether this row matches at all
        // (sync.ts ~890), so a fresh review could match elsewhere or insert.
        if (live["imported_id"] as String?) != existing.financialID { throw changed }
        func stored(_ column: String) -> String? {
            let value: String? = live[column]
            return value?.isEmpty == false ? value : nil
        }
        func reviewed(_ value: String?) -> String? {
            value?.isEmpty == false ? value : nil
        }
        if update.payeeID != existing.payeeID, stored("payee") != reviewed(existing.payeeID) { throw changed }
        if update.categoryID != existing.categoryID, stored("category") != reviewed(existing.categoryID) { throw changed }
        if update.notes != existing.notes, stored("notes") != reviewed(existing.notes) { throw changed }
        if update.cleared != existing.cleared, database.flexibleBool(live["cleared"]) != existing.cleared { throw changed }
        // The cleared cascade only reaches children that are still live.
        if !update.childIDs.isEmpty {
            let split = database.transactionSplitQueryExpressions(columns: columns, tableAlias: "transactions")
            let liveChildren = try Set(String.fetchAll(
                db,
                sql: """
                    SELECT id FROM transactions
                    WHERE \(split.parentID) = ? AND (\(split.isChild)) = 1
                      AND \(database.predicateForLiveRows(columns: columns))
                    """,
                arguments: [update.existingID]
            ))
            guard Set(update.childIDs).isSubset(of: liveChildren) else { throw changed }
        }
    }
}

extension BudgetDatabase {
    /// The account's saved import preferences.
    func importPreferences(keys: [String]) throws -> [String: String] {
        try queue.read { db in try TransactionImportSQL.preferences(keys: keys, in: self, db: db) }
    }

    /// The categories a file import matches its category text against.
    func importCategoryList() throws -> [ImportCategoryMatcher.Category] {
        try queue.read { db in try TransactionImportSQL.categoryList(in: self, db: db) }
    }

    /// Single atomic commit for a file import. The messages come from the
    /// shared import reconcile step; the preconditions run in the same write
    /// transaction, so a match that changed after review, or a row someone else
    /// imported with the same `imported_id`, rejects the whole import and
    /// writes nothing.
    func commitTransactionCSVImport(
        accountID: String,
        messages: [ActualSyncDecodedMessage],
        matches: [TransactionImportSQL.Match],
        expectedAbsentImportedIDs: ImportedIDAbsence,
        now: Date = Date()
    ) throws {
        try Task.checkCancellation()
        _ = try commitLocalPlan(now: now) { db in
            try Task.checkCancellation()
            try TransactionImportSQL.validateMatches(matches, accountID: accountID, in: self, db: db)
            try validateImportedIDsAbsent(expectedAbsentImportedIDs, db: db)
            return LocalCommitPlan(drafts: messages, action: nil, outcome: ())
        }
    }
}
