import Foundation
import GRDB

extension BudgetDatabase {

    func budgetTable(db: Database) throws -> BudgetTable {
        try isTrackingBudget(db: db) ? .tracking : .envelope
    }

    /// Envelope-vs-tracking switch for callers that do not already hold a
    /// `Database` read connection (overspent alerts, view models). Mirrors
    /// Actual web's `budgetType === 'tracking'` branch. Defaults to envelope
    /// (false) when the `preferences` table or row is absent.
    func isTrackingBudget() throws -> Bool {
        try queue.read { db in try isTrackingBudget(db: db) }
    }

    func isTrackingBudget(db: Database) throws -> Bool {
        // A missing table means envelope; a table without `id`/`value` is a
        // damaged download.
        if try !tableExists("preferences", db: db) {
            return false
        }
        if try SyncedPreferences.availability(in: self, db: db) == .unavailable {
            throw LocalFirstError.invalidDownloadedBudget
        }
        return try SyncedPreferences.value(.budgetType, in: self, db: db) == "tracking"
    }

    func requiredColumns(
        table: String,
        required: [String],
        db: Database
    ) throws -> Set<String> {
        guard try tableExists(table, db: db) else {
            throw LocalFirstError.schemaUnavailable("missing \(table) table")
        }
        let columns = try columnSet(for: table, db: db)
        for column in required where !columns.contains(column) {
            throw LocalFirstError.schemaUnavailable("missing column \(table).\(column)")
        }
        return columns
    }

    func firstExistingColumn(
        _ candidates: [String],
        in columns: Set<String>,
        table: String
    ) throws -> String {
        for candidate in candidates where columns.contains(candidate) {
            return candidate
        }
        throw LocalFirstError.schemaUnavailable("missing column \(table).\(candidates.joined(separator: "|"))")
    }

    func categoryMappingTransferColumn(db: Database) throws -> String? {
        guard try tableExists("category_mapping", db: db) else { return nil }
        return try firstExistingColumn(
            ["transferId", "transfer_id"],
            in: columnSet(for: "category_mapping", db: db),
            table: "category_mapping"
        )
    }

    func rowExists(table: String, rowID: String, db: Database) throws -> Bool {
        if table == "zero_budgets",
           try tableExists("zero_budgets", db: db),
           try !columnSet(for: "zero_budgets", db: db).contains("id") {
            let key = try zeroBudgetKey(from: rowID)
            return try Row.fetchOne(
                db,
                sql: "SELECT category FROM zero_budgets WHERE \(normalizedMonthExpression("month")) = ? AND category = ? LIMIT 1",
                arguments: [key.monthID, key.categoryID]
            ) != nil
        }

        return try Row.fetchOne(
            db,
            sql: "SELECT id FROM \(quotedIdentifier(table)) WHERE id = ? LIMIT 1",
            arguments: [rowID]
        ) != nil
    }

    /// Existence check for write validation: a tombstoned or deleted row does not
    /// count. Upserts, sync apply and uniqueness checks keep `rowExists`.
    func liveRowExists(table: String, rowID: String, db: Database) throws -> Bool {
        guard try rowExists(table: table, rowID: rowID, db: db) else { return false }
        guard table != "zero_budgets" else { return true }
        let predicate = predicateForLiveRows(columns: try columnSet(for: table, db: db))
        return try Row.fetchOne(
            db,
            sql: "SELECT id FROM \(quotedIdentifier(table)) WHERE id = ? AND \(predicate) LIMIT 1",
            arguments: [rowID]
        ) != nil
    }

    func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func tableExists(_ table: String, db: Database) throws -> Bool {
        if let cached = tableExistsCache[table] {
            return cached
        }
        let exists = try SQLiteSchema.tableExists(table, in: db)
        tableExistsCache[table] = exists
        return exists
    }

    func columnSet(for table: String, db: Database) throws -> Set<String> {
        if let cached = columnSetCache[table] {
            return cached
        }
        let columns = try SQLiteSchema.columns(of: table, in: db)
        columnSetCache[table] = columns
        return columns
    }

    func column(_ name: String, fallback: String, columns: Set<String>) -> String {
        columns.contains(name) ? name : fallback
    }

    func predicateForLiveRows(columns: Set<String>) -> String {
        if columns.contains("tombstone") {
            return "(tombstone IS NULL OR tombstone = 0)"
        }
        if columns.contains("deleted") {
            return "(deleted IS NULL OR deleted = 0)"
        }
        return "1 = 1"
    }

    func predicateForLiveRows(columns: Set<String>, tableAlias: String) -> String {
        if columns.contains("tombstone") {
            return "(\(tableAlias).tombstone IS NULL OR \(tableAlias).tombstone = 0)"
        }
        if columns.contains("deleted") {
            return "(\(tableAlias).deleted IS NULL OR \(tableAlias).deleted = 0)"
        }
        return "1 = 1"
    }

    func normalizedDateExpression(_ column: String) -> String {
        let text = "CAST(\(column) AS TEXT)"
        return """
            CASE
                WHEN length(\(text)) = 8
                    THEN substr(\(text), 1, 4) || '-' || substr(\(text), 5, 2) || '-' || substr(\(text), 7, 2)
                ELSE \(text)
            END
            """
    }

    func normalizedMonthExpression(_ column: String) -> String {
        let text = "CAST(\(column) AS TEXT)"
        return """
            CASE
                WHEN length(\(text)) = 6 THEN substr(\(text), 1, 4) || '-' || substr(\(text), 5, 2)
                WHEN length(\(text)) = 8 THEN substr(\(text), 1, 4) || '-' || substr(\(text), 5, 2)
                ELSE substr(\(text), 1, 7)
            END
            """
    }

    static func actualDateValue(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) throws -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }
        return year * 10_000 + month * 100 + day
    }

    static func actualMonthValue(_ month: String) throws -> Int {
        let normalized = month.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = PackedDate.compact(normalized)
        guard compact.count == 6,
              let value = Int(compact),
              YearMonth(year: value / 100, month: value % 100) != nil else {
            throw LocalFirstError.invalidLocalWrite("invalid month")
        }
        return value
    }
}
