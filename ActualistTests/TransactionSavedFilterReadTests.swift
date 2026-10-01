import Foundation
import GRDB
import Testing
@testable import Actualist

struct TransactionSavedFilterReadTests {
    @Test func supportedRowsRetainRawJSONAndProjectMultiIDConditions() async throws {
        let raw = "[{\"field\":\"account\",\"op\":\"oneOf\",\"value\":[\"acct-b\",\"acct-a\"],\"type\":\"id\"}]"
        let database = try database(rows: [
            ("filter-1", "  Accounts  ", raw, "and", 0),
            ("filter-deleted", "Deleted", raw, "and", 1),
        ])

        guard case .available(let filters) = try await database.fetchSavedTransactionFilters() else {
            Issue.record("Expected saved-filter capability")
            return
        }
        let filter = try #require(filters.first { $0.id == "filter-1" })
        #expect(filter.name == "  Accounts  ")
        #expect(filter.rawName == "  Accounts  ")
        #expect(filter.rawConditionsJSON == raw)
        #expect(filter.isSupported)
        #expect(filter.queryJoin == .and)
        #expect(filter.queryConditions == [
            .account(.oneOf(["acct-a", "acct-b" ])),
        ])
        #expect(filters.first { $0.id == "filter-deleted" }?.tombstone == true)
    }

    @Test func absentJoinDefaultsToAndAndDisplaySortDoesNotRewriteNames() async throws {
        let database = try database(rows: [
            ("filter-z", "  Zebra", "[]", nil, 0),
            ("filter-a", "Alpha  ", "[]", nil, 0),
        ], includeJoinColumn: false)

        guard case .available(let filters) = try await database.fetchSavedTransactionFilters() else {
            Issue.record("Expected saved-filter capability")
            return
        }
        #expect(filters.map(\.id) == ["filter-a", "filter-z"])
        #expect(filters.map(\.name) == ["Alpha  ", "  Zebra"])
        #expect(filters.allSatisfy { $0.compatibility != .supported })
    }

    @Test func unsupportedRowsRemainLosslessAndNeverProduceAQuery() {
        let fixtures: [(String?, String?, String)] = [
            ("not json", "and", "Malformed"),
            ("[]", "xor", "Unknown join"),
            ("[{\"field\":\"future\",\"op\":\"is\",\"value\":\"x\",\"futureKey\":1}]", "and", "Unknown key"),
            ("[{\"field\":\"date\",\"op\":\"is\",\"value\":\"2026-09\"}]", "and", "Unsupported date precision"),
        ]
        for (raw, join, name) in fixtures {
            let filter = SavedTransactionFilter.project(
                id: name,
                name: name,
                rawConditionsJSON: raw,
                conditionsOperation: join,
                tombstone: false
            )
            #expect(!filter.isSupported)
            #expect(filter.rawConditionsJSON == raw)
            #expect(filter.rawName == name)
            #expect(filter.queryConditions == nil)
        }
    }

    @Test func missingTableAndRequiredColumnsReportUnavailable() async throws {
        let missingTable = try emptyDatabase()
        guard case .unavailable = try await missingTable.fetchSavedTransactionFilters() else {
            Issue.record("Missing table must not appear as an empty supported list")
            return
        }
        let missingColumns = try database(rows: [], schema: "CREATE TABLE transaction_filters (id TEXT)")
        guard case .unavailable = try await missingColumns.fetchSavedTransactionFilters() else {
            Issue.record("Missing required columns must be unavailable")
            return
        }
    }

    @Test func comparatorMatchesSourceDirectionalMultiplicityAndIgnoresType() throws {
        let a = try condition(#"{"field":"account","op":"is","value":"a","type":"id"}"#)
        let aOtherType = try condition(#"{"field":"account","op":"is","value":"a","type":"string"}"#)
        let b = try condition(#"{"field":"account","op":"is","value":"b","type":"id"}"#)
        let storedAB = try filter("ab", conditions: [a, b])
        let storedAA = try filter("aa", conditions: [a, a])

        #expect(SavedTransactionFilterComparator.hasDuplicateConditions(
            candidate: [aOtherType, a], join: .and, among: [storedAB]
        ))
        #expect(!SavedTransactionFilterComparator.hasDuplicateConditions(
            candidate: [a, b], join: .and, among: [storedAA]
        ))
    }

    @Test func comparatorNormalizesNullishOptionsAndKeepsCompoundOperandsSupported() throws {
        let absent = try condition(#"{"field":"account","op":"is","value":"a"}"#)
        let nullOptions = try condition(#"{"field":"account","op":"is","value":"a","options":null}"#)
        let emptyOptions = try condition(#"{"field":"account","op":"is","value":"a","options":{}}"#)
        let arrayValue = try condition(#"{"field":"account","op":"oneOf","value":["a","b"]}"#)
        let equalArray = try condition(#"{"field":"account","op":"oneOf","value":["a","b"]}"#)
        let absentFilter = try filter("absent", conditions: [absent], join: "and")

        for candidate in [nullOptions, emptyOptions] {
            #expect(SavedTransactionFilterComparator.hasDuplicateConditions(
                candidate: [candidate], join: .or,
                among: [absentFilter]
            ))
        }
        let arrayFilter = try filter("array", conditions: [arrayValue])
        #expect(arrayFilter.isSupported)
        #expect(!SavedTransactionFilterComparator.hasDuplicateConditions(
            candidate: [equalArray], join: .and, among: [arrayFilter]
        ))
    }

    private func filter(
        _ id: String,
        conditions: [RuleCondition],
        join: String = "and"
    ) throws -> SavedTransactionFilter {
        let data = try JSONEncoder().encode(conditions)
        let raw = String(decoding: data, as: UTF8.self)
        return SavedTransactionFilter.project(
            id: id, name: id, rawConditionsJSON: raw,
            conditionsOperation: join, tombstone: false
        )
    }

    private func condition(_ json: String) throws -> RuleCondition {
        try JSONDecoder().decode(RuleCondition.self, from: Data(json.utf8))
    }

    private func database(
        rows: [(String, String, String?, String?, Int)],
        includeJoinColumn: Bool = true,
        schema: String? = nil
    ) throws -> BudgetDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistSavedFilters-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        if let schema {
            try queue.write { db in try db.execute(sql: schema) }
        } else {
            let joinColumn = includeJoinColumn ? ", conditions_op TEXT" : ""
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE transaction_filters (id TEXT, name TEXT, conditions TEXT\(joinColumn), tombstone INTEGER)")
                for (id, name, conditions, join, tombstone) in rows {
                    if includeJoinColumn {
                        try db.execute(
                            sql: "INSERT INTO transaction_filters (id, name, conditions, conditions_op, tombstone) VALUES (?, ?, ?, ?, ?)",
                            arguments: [id, name, conditions, join, tombstone]
                        )
                    } else {
                        try db.execute(
                            sql: "INSERT INTO transaction_filters (id, name, conditions, tombstone) VALUES (?, ?, ?, ?)",
                            arguments: [id, name, conditions, tombstone]
                        )
                    }
                }
            }
        }
        return try BudgetDatabase(databaseURL: url)
    }

    private func emptyDatabase() throws -> BudgetDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistSavedFiltersEmpty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try BudgetDatabase(databaseURL: directory.appending(path: "db.sqlite"))
    }
}
