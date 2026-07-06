import Foundation
import GRDB

extension BudgetDatabase {

    func monthInt(_ month: String) -> Int {
        Int(month.replacingOccurrences(of: "-", with: "")) ?? 0
    }

    func monthID(_ month: Int) -> String {
        let year = month / 100
        let monthNumber = month % 100
        return String(format: "%04d-%02d", year, monthNumber)
    }

    func compareDayID(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs)
    }

    func shiftedMonth(_ month: Int, by offset: Int) -> Int {
        let year = month / 100
        let monthNumber = month % 100
        let zeroBased = year * 12 + (monthNumber - 1) + offset
        let shiftedYear = zeroBased / 12
        let shiftedMonth = zeroBased % 12 + 1
        return shiftedYear * 100 + shiftedMonth
    }

    func nextMonth(after month: Int) -> Int {
        let year = month / 100
        let monthNumber = month % 100
        if monthNumber == 12 {
            return (year + 1) * 100 + 1
        }
        return year * 100 + monthNumber + 1
    }

    func date(fromDayID dayID: String) -> Date? {
        let parts = dayID.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day)
        )
    }

    func dayIDString(from date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    func requiredColumns(
        table: String,
        required: [String],
        db: Database
    ) throws -> Set<String> {
        guard try tableExists(table, db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing \(table) table")
        }
        let columns = try columnSet(for: table, db: db)
        for column in required where !columns.contains(column) {
            throw LocalFirstError.invalidLocalWrite("missing column \(table).\(column)")
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
        throw LocalFirstError.invalidLocalWrite("missing column \(table).\(candidates.joined(separator: "|"))")
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

    func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func tableExists(_ table: String, db: Database) throws -> Bool {
        try Row.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil
    }

    func columnSet(for table: String, db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0["name"] as String? })
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

    func parentTransactionPredicate(columns: Set<String>) -> String {
        var predicates: [String] = []
        if columns.contains("parent_id") {
            predicates.append("parent_id IS NULL")
        }
        if columns.contains("is_child") {
            predicates.append("(is_child IS NULL OR is_child = 0)")
        }
        if columns.contains("is_parent") {
            predicates.append("(is_parent IS NULL OR is_parent = 0)")
        }
        return predicates.isEmpty ? "1 = 1" : predicates.joined(separator: " AND ")
    }

    func parentTransactionPredicate(columns: Set<String>, tableAlias: String) -> String {
        var predicates: [String] = []
        if columns.contains("parent_id") {
            predicates.append("\(tableAlias).parent_id IS NULL")
        }
        if columns.contains("is_child") {
            predicates.append("(\(tableAlias).is_child IS NULL OR \(tableAlias).is_child = 0)")
        }
        if columns.contains("is_parent") {
            predicates.append("(\(tableAlias).is_parent IS NULL OR \(tableAlias).is_parent = 0)")
        }
        return predicates.isEmpty ? "1 = 1" : predicates.joined(separator: " AND ")
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

    func flexibleString(_ value: DatabaseValueConvertible?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? Int {
            return String(value)
        }
        if let value = value as? Int64 {
            return String(value)
        }
        return nil
    }

    func canonicalMonthID(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split { character in
            character == "-" || character == "/" || character == "."
        }
        if parts.count >= 2,
           let year = Int(parts[0]),
           let month = Int(parts[1]),
           let monthID = canonicalMonthID(year: year, month: month) {
            return monthID
        }

        let digits = String(trimmed.prefix { $0.isNumber })
        guard digits.count >= 6 else {
            return nil
        }

        let yearEnd = digits.index(digits.startIndex, offsetBy: 4)
        let monthEnd = digits.index(yearEnd, offsetBy: 2)
        guard let year = Int(digits[..<yearEnd]),
              let month = Int(digits[yearEnd..<monthEnd]) else {
            return nil
        }

        return canonicalMonthID(year: year, month: month)
    }

    func canonicalMonthID(year: Int, month: Int) -> String? {
        guard (1900...9999).contains(year), (1...12).contains(month) else {
            return nil
        }

        return String(format: "%04d-%02d", year, month)
    }

    func flexibleBool(_ value: DatabaseValueConvertible?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? Int {
            return value != 0
        }
        if let value = value as? Int64 {
            return value != 0
        }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }

    func actualAmountToMinorUnits(_ amount: Int) -> Int {
        amount
    }

    static func actualDateValue(_ date: Date) throws -> Int {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }
        return year * 10_000 + month * 100 + day
    }

    static func actualMonthValue(_ month: String) throws -> Int {
        let normalized = month.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = normalized.replacingOccurrences(of: "-", with: "")
        guard compact.count == 6, let value = Int(compact) else {
            throw LocalFirstError.invalidLocalWrite("invalid month")
        }
        return value
    }
}
