import Foundation
import GRDB
@testable import Actualist

/// Replays Rules oracle cases through the production preview that Bank Sync and manual entry use:
/// `BudgetDatabase.previewRules(for:dateTimeZone:)`. Each case seeds the fixture's upstream rows
/// into the starter schema, then every run builds a `TransactionDraft` from the input transaction and
/// compares the overlaid preview with the oracle's `runRules` output. The compared and excluded fields
/// are documented in `scripts/rule-parity/README.md` ("Swift replay").
@MainActor
enum RuleOracleReplay {
    /// The fixture's `timeZone`; the draft's civil day and every day string use it.
    static let timeZone = TimeZone(identifier: "America/New_York")!

    /// Input tables, parents before children. Each is cleared of starter rows and refilled from the case.
    private static let seedTables = [
        "accounts", "category_groups", "categories", "category_mapping", "payees", "payee_mapping",
        "rules", "schedules", "schedules_next_date", "transactions",
    ]

    struct RunResult {
        let label: String
        /// Whole normalized expected and actual values, built from the same key set.
        let expected: OracleValue
        let actual: OracleValue
        var mismatches: [ReplayMismatch] {
            var comparison = OracleComparison()
            comparison.compare(expected: expected, actual: actual, path: label)
            return comparison.mismatches
        }
    }

    struct CaseResult {
        let runs: [RunResult]
        /// Runs not replayed because production drafts cannot carry an absent id field; see `isReplayable`.
        let skippedRuns: [String]
    }

    static func replay(_ entry: [String: Any]) async throws -> CaseResult {
        let input = try OracleJSON.object(entry["input"], "input")
        let runs = try OracleJSON.objects(entry["runs"], "runs")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RuleOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "db.sqlite")
        _ = try BudgetDatabase.makeNewBudgetStarterDatabase(at: url)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")
        try await seed(database, input: input)

        let payees = try Dictionary(
            uniqueKeysWithValues: OracleJSON.objects(input["payees"], "payees").map {
                (try OracleJSON.string($0, "id"), $0)
            }
        )

        var results: [RunResult] = []
        var skipped: [String] = []
        for run in runs {
            let label = try OracleJSON.string(run, "label")
            let transaction = try OracleJSON.object(run["transaction"], "transaction of \(label)")
            guard isReplayable(transaction) else {
                skipped.append(label)
                continue
            }
            let draft = try makeDraft(transaction, payees: payees)
            let previews = try await database.previewRules(for: [draft], dateTimeZone: timeZone)
            guard let preview = previews.first else {
                throw OracleReplayError.malformedFixture("no preview for \(label)")
            }
            results.append(RunResult(
                label: label,
                expected: try expectedValue(run["output"], label: label),
                actual: actualValue(draft: draft, preview: preview)
            ))
        }
        return CaseResult(runs: results, skippedRuns: skipped)
    }

    /// A production draft always carries its payee, category and account (null when unset), so a run whose
    /// input leaves an id field absent cannot be expressed. Upstream fails every operator on an absent id
    /// field, including `isNot`; that distinction is documented in the README and not replayed.
    ///
    /// A run whose input carries `transfer` or `parent` is not replayable either: production drafts never supply
    /// them, and rule matching never reads their own transfer/parent state (OP-44), so those runs cannot be expressed.
    private static func isReplayable(_ transaction: [String: Any]) -> Bool {
        ["payee", "category", "account"].allSatisfy { transaction[$0] != nil }
            && transaction["transfer"] == nil && transaction["parent"] == nil
    }

    // MARK: Drafts

    private static func makeDraft(_ transaction: [String: Any], payees: [String: [String: Any]]) throws -> TransactionDraft {
        let day = try OracleJSON.string(transaction, "date")
        guard let date = ActualDateOnly.date(from: day, timeZone: timeZone) else {
            throw OracleReplayError.malformedFixture("bad date \(day)")
        }
        let payeeID = transaction["payee"] as? String
        let payee = payeeID.flatMap { payees[$0] }
        return TransactionDraft(
            accountID: try OracleJSON.string(transaction, "account"),
            date: date,
            amountMinorUnits: OracleJSON.int(transaction["amount"]) ?? 0,
            payeeID: payeeID,
            payeeName: payee?["name"] as? String ?? "",
            categoryID: transaction["category"] as? String,
            notes: transaction["notes"] as? String,
            cleared: (transaction["cleared"] as? Bool) ?? false,
            isTransfer: payee?["transfer_acct"] is String,
            importedPayee: transaction["imported_payee"] as? String,
            sortOrder: OracleJSON.double(transaction["sort_order"]),
            reconciled: (transaction["reconciled"] as? Bool) ?? false,
            scheduleID: transaction["schedule"] as? String
        )
    }

    // MARK: Values

    /// The fields compared. Not compared: `imported_payee`, `reconciled`, `_ruleErrors`, created payees,
    /// `is_parent`, `error`, child `id`, and the `evaluated` and `applied` lists.
    private static func expectedValue(_ output: Any?, label: String) throws -> OracleValue {
        let fields = try OracleJSON.object(output, "output of \(label)")
        func read(_ source: [String: Any], _ key: String) throws -> OracleValue {
            try OracleValue(json: source[key] ?? NSNull())
        }
        var splits: [OracleValue] = []
        for child in (fields["subtransactions"] as? [[String: Any]]) ?? [] {
            var split: [String: OracleValue] = [:]
            split["amount"] = try read(child, "amount")
            split["category"] = try read(child, "category")
            split["payee"] = try read(child, "payee")
            split["notes"] = try read(child, "notes")
            split["sortOrder"] = try read(child, "sort_order")
            splits.append(.object(split))
        }
        var expected: [String: OracleValue] = [:]
        for key in ["account", "date", "amount", "payee", "notes", "category", "cleared", "schedule"] {
            expected[key] = try read(fields, key)
        }
        expected["deleted"] = .number(OracleJSON.int(fields["tombstone"]) == 1 ? 1 : 0)
        expected["splits"] = .array(splits)
        return .object(expected)
    }

    /// The final transaction: each preview field overlays the draft. The preview reports an unchanged
    /// account, payee, amount, date and cleared as nil, so nil means "keep the draft's value".
    private static func actualValue(draft: TransactionDraft, preview: TransactionRulePreview) -> OracleValue {
        var splits: [OracleValue] = []
        for split in preview.splits {
            var child: [String: OracleValue] = [:]
            child["amount"] = .number(Double(split.amountMinorUnits))
            child["category"] = text(split.categoryID)
            child["payee"] = text(optional(split.payeeID))
            child["notes"] = text(optional(split.notes))
            if let order = optional(split.sortOrder) {
                child["sortOrder"] = .number(order)
            } else {
                child["sortOrder"] = .null
            }
            splits.append(.object(child))
        }
        var fields: [String: OracleValue] = [:]
        fields["account"] = .string(preview.accountID ?? draft.accountID)
        let day = ActualDateOnly.dayID(from: preview.date ?? draft.date, timeZone: timeZone)
        fields["date"] = .string(day)
        fields["amount"] = .number(Double(preview.amountMinorUnits ?? draft.amountMinorUnits))
        fields["payee"] = text(preview.clearsPayee ? nil : preview.payeeID ?? draft.payeeID)
        fields["notes"] = text(preview.notes)
        fields["category"] = text(preview.categoryID)
        fields["cleared"] = .number((preview.cleared ?? draft.cleared) ? 1 : 0)
        fields["schedule"] = text(preview.scheduleID)
        fields["deleted"] = .number(preview.deletesTransaction ? 1 : 0)
        fields["splits"] = .array(splits)
        return .object(fields)
    }

    private static func text(_ value: String?) -> OracleValue {
        if let value { return .string(value) }
        return .null
    }

    private static func optional<Value>(_ field: SplitOptionalField<Value>) -> Value? {
        if case .value(let value) = field { return value }
        return nil
    }

    // MARK: Seeding

    private struct SeedRow: Sendable {
        let table: String
        let sql: String
        let values: [DatabaseValue]
    }

    private static func seed(_ database: BudgetDatabase, input: [String: Any]) async throws {
        var rows: [SeedRow] = []
        for table in seedTables {
            for row in try OracleJSON.objects(input[table] ?? [], table) {
                let columns = row.keys.sorted()
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                rows.append(SeedRow(
                    table: table,
                    sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
                    values: try columns.map { try databaseValue(row[$0] ?? NSNull(), column: "\(table).\($0)") }
                ))
            }
        }
        let queue = await database.queue
        let tables = Array(seedTables.reversed())
        let insertions = rows
        try await queue.write { db in
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for row in insertions {
                try db.execute(sql: row.sql, arguments: StatementArguments(row.values as [any DatabaseValueConvertible]))
            }
        }
    }

    private static func databaseValue(_ value: Any, column: String) throws -> DatabaseValue {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return string.databaseValue
        case let number as NSNumber:
            // JSONSerialization yields booleans as NSNumber; the upstream rows store them as 0 or 1.
            if String(cString: number.objCType) == "d" { return number.doubleValue.databaseValue }
            return number.int64Value.databaseValue
        default:
            throw OracleReplayError.malformedFixture("unsupported value in \(column)")
        }
    }
}
