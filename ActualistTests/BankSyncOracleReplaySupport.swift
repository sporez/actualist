import Foundation
import GRDB
@testable import Actualist

/// Replays BankSync oracle cases through the production import reconcile that CSV import and Bank Sync
/// share: rule projection (`ImportReconcileProjection`), `reconcileProjectedImport`,
/// `importReconcileWrites`, and the Bank Sync opening balance, committed to a seeded starter database.
/// The compared and excluded parts are documented in `scripts/bank-sync-parity/README.md` ("Swift replay").
@MainActor
enum BankSyncOracleReplay {
    /// The fixture's `timeZone`; CSV dates are ISO calendar days in it.
    static let timeZone = TimeZone(identifier: "America/New_York")!

    struct Comparison {
        let expected: OracleValue
        let actual: OracleValue
        /// Candidates production built (CSV) that differ from the post-mapping transaction the oracle recorded.
        let candidateMismatches: [ReplayMismatch]
        var mismatches: [ReplayMismatch] {
            var comparison = OracleComparison()
            comparison.compare(expected: expected, actual: actual)
            return candidateMismatches + comparison.mismatches
        }
    }

    private static let seedTables = [
        "accounts", "category_groups", "categories", "category_mapping", "payees", "payee_mapping",
        "rules", "schedules", "schedules_next_date", "transactions",
    ]

    static func replay(_ entry: [String: Any], fixture: BankSyncOracleFixture) async throws -> Comparison {
        if let error = entry["error"] as? String {
            throw OracleReplayError.malformedFixture("replayed case recorded an error: \(error)")
        }
        let call = try OracleJSON.object(entry["call"], "call")
        let input = try OracleJSON.object(entry["input"], "input")
        let kind = try OracleJSON.string(call, "kind")
        let accountID = try OracleJSON.string(call, "accountId")
        let options = try OracleJSON.object(call["options"], "options")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BankSyncOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "db.sqlite")
        _ = try BudgetDatabase.makeNewBudgetStarterDatabase(at: url)
        let database = try BudgetDatabase(databaseURL: url, localNodeID: "node1")
        try await seed(
            database,
            tables: fixture.worldTables.merging(input) { _, caseRows in caseRows },
            prefs: try OracleJSON.object(OracleJSON.object(entry["setup"], "setup")["prefs"], "prefs")
        )

        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: UUID().uuidString, account: "token", backend: FakeKeychainBackend())
        )
        let payees = try await database.fetchPayees(orderedForPicker: false)
        let categories = try await database.fetchCategories()
        let transferPayeeIDs = Set(payees.compactMap { $0.transferAccount?.isEmpty == false ? $0.id : nil })
        let accountIsOffBudget = try await database.accountIsOffBudget(accountID)
        let reconcileOptions = Self.reconcileOptions(kind: kind, options: options)
        let recorded = try OracleJSON.objects(entry["candidates"], "candidates")
        let afterRecord = try OracleJSON.object(entry["after"], "after")
        let newPayeeNames = Self.newPayeeNames(afterRecord)

        var candidateMismatches: [ReplayMismatch] = []
        let candidates: [BankSyncReconciliation.Candidate]
        if kind == "csv" {
            let transactions = try OracleJSON.objects(call["transactions"], "transactions")
            let lookup = Self.lookup(payees: payees, categories: categories, transferPayeeIDs: transferPayeeIDs)
            candidates = TransactionCSVImportCandidates.candidates(
                rows: try Self.csvRows(transactions, categories: categories),
                lookup: lookup,
                options: reconcileOptions
            )
            candidateMismatches = Self.candidateMismatches(candidates, recorded: recorded)
        } else {
            candidates = try Self.recordedCandidates(recorded, newPayeeNames: newPayeeNames)
        }

        let drafts = candidates.map { ImportReconcileProjection.previewDraft(for: $0, accountID: accountID) }
        let previews = try await database.previewRules(for: drafts, dateTimeZone: ImportReconcileProjection.ruleDateTimeZone)
        let projection = ImportReconcileProjection.project(
            candidates: candidates,
            previews: previews,
            accountID: accountID,
            accountIsOffBudget: accountIsOffBudget
        )
        guard projection.movedSources.isEmpty else {
            throw OracleReplayError.malformedFixture("a rule moved a replayed import to another account")
        }
        // Both sources match by imported id wherever the stored row sits.
        let importedIDs = Set(candidates.compactMap(\.financialID))
        let outcome = try await store.reconcileProjectedImport(
            database: database,
            accountID: accountID,
            accountIsOffBudget: accountIsOffBudget,
            candidateDayIDs: candidates.map(\.dayID),
            importedIDs: importedIDs,
            projected: projection.candidates,
            options: reconcileOptions
        )

        let isPreview = options["isPreview"] as? Bool == true
        if !isPreview {
            try await write(
                outcome: outcome,
                store: store,
                database: database,
                accountID: accountID,
                accountIsOffBudget: accountIsOffBudget,
                options: reconcileOptions,
                openingBalance: kind == "simplefin" ? OracleJSON.int(options["startingBalance"]) ?? 0 : nil,
                earliestDayID: candidates.map(\.dayID).min()
            )
        }

        let actual = try await actualValue(
            outcome: outcome,
            database: database,
            input: input,
            worldTables: fixture.worldTables
        )
        let expected = try expectedValue(entry, input: input, worldTables: fixture.worldTables)
        return Comparison(expected: expected, actual: actual, candidateMismatches: candidateMismatches)
    }

    // MARK: Options

    /// The production defaults for the kind, with the call's upstream options laid over them. A `simplefin`
    /// call reads the seeded `sync-update-dates-<account>` preference, as production does; a `bank` or
    /// `csv` call passes the option (production's file import never sets it).
    private static func reconcileOptions(kind: String, options: [String: Any]) -> ImportReconcileOptions {
        var result: ImportReconcileOptions = kind == "csv" ? .csv : .bankSync
        // A direct `bank` call is a provider whose accounts use upstream's default strict id checking.
        // Actualist has only SimpleFIN, whose accounts turn it off, so `simplefin` keeps `.bankSync`.
        if kind == "bank" {
            result.strictIdChecking = true
            result.updateDates = false
        }
        if let updateDates = options["updateDates"] as? Bool { result.updateDates = updateDates }
        if let strict = options["strictIdChecking"] as? Bool { result.strictIdChecking = strict }
        if let reimport = options["reimportDeleted"] as? Bool { result.reimportDeleted = reimport }
        if let cleared = options["defaultCleared"] as? Bool { result.defaultCleared = cleared }
        switch options["payeeNameNormalization"] as? String {
        case "original": result.payeeNameNormalization = .original
        case "title-case": result.payeeNameNormalization = .titleCase
        default: break
        }
        return result
    }

    // MARK: Candidates

    private static func lookup(
        payees: [ActualPayee],
        categories: [ActualCategory],
        transferPayeeIDs: Set<String>
    ) -> TransactionCSVImportLookup {
        // The same name lookups `prepareTransactionCSVImport` builds (private to the store): first live
        // payee or category per lowercased name.
        var payeeIDs: [String: String] = [:]
        for payee in payees {
            guard let id = payee.id, !id.isEmpty, payeeIDs[payee.name.lowercased()] == nil else { continue }
            payeeIDs[payee.name.lowercased()] = id
        }
        var categoryIDs: [String: String] = [:]
        for category in categories {
            guard let id = category.id, !id.isEmpty, categoryIDs[category.name.lowercased()] == nil else { continue }
            categoryIDs[category.name.lowercased()] = id
        }
        return TransactionCSVImportLookup(
            payeeIDByName: payeeIDs,
            transferPayeeIDs: transferPayeeIDs,
            categoryIDByName: categoryIDs
        )
    }

    /// A `transactions-import` row as a CSV row. Upstream names a category by id; the file names it by
    /// its name, so a known id is given as that category's name and an unknown one stays as typed.
    private static func csvRows(
        _ transactions: [[String: Any]],
        categories: [ActualCategory]
    ) throws -> [TransactionCSVImportRow] {
        let namesByID = Dictionary(uniqueKeysWithValues: categories.compactMap { category in
            category.id.map { ($0, category.name) }
        })
        return try transactions.enumerated().map { index, transaction in
            let day = try OracleJSON.string(transaction, "date")
            guard let date = ActualDateOnly.date(from: day, timeZone: timeZone) else {
                throw OracleReplayError.malformedFixture("bad date \(day)")
            }
            let category = transaction["category"] as? String
            return TransactionCSVImportRow(
                id: "row-\(index)",
                sourceLine: index + 1,
                dateText: day,
                date: date,
                amountMinorUnits: OracleJSON.int(transaction["amount"]) ?? 0,
                payeeName: (transaction["payee_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                notes: transaction["notes"] as? String,
                categoryName: category.map { namesByID[$0] ?? $0 },
                cleared: transaction["cleared"] as? Bool,
                importedID: transaction["imported_id"] as? String,
                payeeCellWasEmpty: transaction["payee_name"] as? String == ""
            )
        }
    }

    /// A recorded post-mapping transaction (the input of upstream's rules step) as a candidate. The
    /// provider-side mapping that produced it (`prepareDownload`) is not reproduced.
    private static func recordedCandidates(
        _ recorded: [[String: Any]],
        newPayeeNames: [String: String]
    ) throws -> [BankSyncReconciliation.Candidate] {
        try recorded.map { transaction in
            let day = try OracleJSON.string(transaction, "date")
            let payee = transaction["payee"] as? String
            let isNewPayee = payee?.hasPrefix("uuid-") == true
            let importedPayee = transaction["imported_payee"] as? String
            return BankSyncReconciliation.Candidate(
                financialID: transaction["imported_id"] as? String,
                dayID: day.replacingOccurrences(of: "-", with: ""),
                amountMinorUnits: OracleJSON.int(transaction["amount"]) ?? 0,
                payeeID: isNewPayee ? nil : payee,
                payeeName: isNewPayee ? (payee.flatMap { newPayeeNames[$0] } ?? importedPayee) : nil,
                notes: transaction["notes"] as? String,
                categoryID: transaction["category"] as? String,
                cleared: transaction["cleared"] as? Bool ?? false,
                importedPayee: importedPayee
            )
        }
    }

    /// What production's CSV mapping built, against what upstream's normalization handed its rules.
    private static func candidateMismatches(
        _ candidates: [BankSyncReconciliation.Candidate],
        recorded: [[String: Any]]
    ) -> [ReplayMismatch] {
        guard candidates.count == recorded.count else {
            return [ReplayMismatch(path: "candidates", expected: "\(recorded.count) items", actual: "\(candidates.count) items")]
        }
        var result: [ReplayMismatch] = []
        for (index, pair) in zip(candidates, recorded).enumerated() {
            let (candidate, transaction) = pair
            func check(_ field: String, _ expected: OracleValue, _ actual: OracleValue) {
                if expected != actual {
                    result.append(ReplayMismatch(
                        path: "candidate[\(index)].\(field)", expected: expected.canonical, actual: actual.canonical
                    ))
                }
            }
            func text(_ value: Any?) -> OracleValue { (value as? String).map(OracleValue.string) ?? .null }
            func optional(_ value: String?) -> OracleValue { value.map(OracleValue.string) ?? .null }
            let payee = transaction["payee"] as? String
            check("payee", payee?.hasPrefix("uuid-") == true ? .null : text(payee), optional(candidate.payeeID))
            check("date", text(transaction["date"]), .string(Self.isoDay(candidate.dayID)))
            check("amount", .number(Double(OracleJSON.int(transaction["amount"]) ?? 0)), .number(Double(candidate.amountMinorUnits)))
            check("imported_payee", text(transaction["imported_payee"]), optional(candidate.importedPayee))
            check("notes", text(transaction["notes"]), optional(candidate.notes))
            check("category", text(transaction["category"]), optional(candidate.categoryID))
            check("imported_id", text(transaction["imported_id"]), optional(candidate.financialID))
            if let cleared = transaction["cleared"] as? Bool {
                check("cleared", .number(cleared ? 1 : 0), .number(candidate.clearedIsExplicit && candidate.cleared ? 1 : 0))
            } else {
                check("cleared (explicit)", .number(0), .number(candidate.clearedIsExplicit ? 1 : 0))
            }
        }
        return result
    }

    private static func isoDay(_ dayID: String) -> String {
        "\(dayID.prefix(4))-\(dayID.dropFirst(4).prefix(2))-\(dayID.suffix(2))"
    }

    /// Minted payee id (`uuid-N`) to its name, for the new payees the oracle created.
    private static func newPayeeNames(_ after: [String: Any]) -> [String: String] {
        var names: [String: String] = [:]
        for payee in (after["payees"] as? [[String: Any]]) ?? [] {
            if let id = payee["id"] as? String, id.hasPrefix("uuid-"), let name = payee["name"] as? String {
                names[id] = name
            }
        }
        return names
    }

    // MARK: Writes

    private static func write(
        outcome: ImportReconcileOutcome,
        store: LocalFirstActualStore,
        database: BudgetDatabase,
        accountID: String,
        accountIsOffBudget: Bool,
        options: ImportReconcileOptions,
        openingBalance currentBalance: Int?,
        earliestDayID: String?
    ) async throws {
        let existingByID = Dictionary(outcome.existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var updates: [(update: BankSyncReconciliation.MatchedUpdate, existing: BankSyncReconciliation.Existing)] = []
        for entry in outcome.plan.entries {
            guard case .update(let update) = entry, let existing = existingByID[update.existingID] else { continue }
            updates.append((update, existing))
        }
        var builder = LocalFirstSyncMessageBuilder()
        let sortBase = 1_000_000.0
        let writes = try await store.importReconcileWrites(
            database: database,
            accountID: accountID,
            accountIsOffBudget: accountIsOffBudget,
            updates: updates,
            inserts: outcome.plan.inserts,
            options: options,
            sortOrder: { sortBase - Double($0) },
            builder: &builder
        )
        var messages = writes.messages
        if let currentBalance {
            // Bank Sync's first-sync step: the account's first sync writes a Starting Balance row.
            let hadLiveTransactions = try await database.bankSyncOldestLiveTransactionDayID(accountID: accountID, todayDayID: "20261015") != nil
            if let opening = BankSyncReconciliation.openingBalance(
                currentBalanceMinorUnits: currentBalance,
                inserts: outcome.plan.inserts,
                earliestDayID: earliestDayID,
                accountHadLiveTransactions: hadLiveTransactions
            ) {
                messages = try await database.makeBankSyncOpeningBalanceMessages(
                    transactionID: UUID().uuidString,
                    accountID: accountID,
                    openingBalance: opening,
                    onBudget: !accountIsOffBudget,
                    sortOrder: sortBase + 1,
                    builder: &builder
                ) + messages
            }
        }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
    }

    // MARK: Values

    private static func rows(_ value: Any?, _ name: String) throws -> [[String: OracleValue]] {
        try OracleJSON.objects(value, name).map { row in
            try row.mapValues { try OracleValue(json: $0) }
        }
    }

    private static func ids(_ value: Any?, _ name: String) throws -> Set<String> {
        Set(try OracleJSON.objects(value, name).map { try OracleJSON.string($0, "id") })
    }

    private static func expectedValue(
        _ entry: [String: Any],
        input: [String: Any],
        worldTables: [String: Any]
    ) throws -> OracleValue {
        let result = try expectedResult(entry)
        let after = try OracleJSON.object(entry["after"], "after")
        let state = BankSyncOracleState.canonical(
            transactions: try rows(after["transactions"], "after.transactions"),
            payees: try rows(after["payees"], "after.payees"),
            rules: try rows(after["rules"], "after.rules"),
            baselineTransactionIDs: try ids(input["transactions"], "input.transactions"),
            baselinePayeeIDs: try ids(worldTables["payees"], "worldTables.payees")
        )
        guard case .object(var fields) = state else { return state }
        fields["result"] = result
        return .object(fields)
    }

    /// Classification of the oracle's result: the rows it updated, the matches it left alone, and how
    /// many rows it added (a first-sync Starting Balance row is not an imported row).
    private static func expectedResult(_ entry: [String: Any]) throws -> OracleValue {
        var raw = entry["result"]
        if let batch = raw as? [[String: Any]], let first = batch.first {
            raw = first["res"]
        }
        let result = try OracleJSON.object(raw, "result")
        let after = try OracleJSON.object(entry["after"], "after")
        let added = (result["added"] as? [String]) ?? []
        let startingRows = Set(try OracleJSON.objects(after["transactions"], "after.transactions")
            .filter { OracleJSON.int($0["starting_balance_flag"]) == 1 }
            .compactMap { $0["id"] as? String })
        // The first-sync Starting Balance row can itself be matched by a later download.
        let updated = ((result["updated"] as? [String]) ?? []).filter { !startingRows.contains($0) }.sorted()
        let ignored = ((result["updatedPreview"] as? [[String: Any]]) ?? []).filter { $0["ignored"] as? Bool == true }.count
        return .object([
            "updated": .array(updated.map(OracleValue.string)),
            "ignored": .number(Double(ignored)),
            "skippedDeleted": .number(0),
            "addedCount": .number(Double(added.filter { !startingRows.contains($0) }.count)),
        ])
    }

    private static func actualValue(
        outcome: ImportReconcileOutcome,
        database: BudgetDatabase,
        input: [String: Any],
        worldTables: [String: Any]
    ) async throws -> OracleValue {
        var updated: [String] = []
        var ignored = 0
        var skipped = 0
        for entry in outcome.plan.entries {
            switch entry {
            case .update(let update): updated += [update.existingID] + update.childIDs
            case .unchanged: ignored += 1
            case .skippedDeleted: skipped += 1
            case .insert: break
            }
        }
        let addedCount = outcome.plan.inserts.reduce(0) { $0 + 1 + $1.splits.count }
        let result: OracleValue = .object([
            "updated": .array(updated.sorted().map(OracleValue.string)),
            "ignored": .number(Double(ignored)),
            "skippedDeleted": .number(Double(skipped)),
            "addedCount": .number(Double(addedCount)),
        ])
        let state = try await readState(database, input: input, worldTables: worldTables)
        guard case .object(var fields) = state else { return state }
        fields["result"] = result
        return .object(fields)
    }

    private static func readState(
        _ database: BudgetDatabase,
        input: [String: Any],
        worldTables: [String: Any]
    ) async throws -> OracleValue {
        let queue = await database.queue
        let (transactions, payees, rules) = try await queue.read { db -> ([[String: OracleValue]], [[String: OracleValue]], [[String: OracleValue]]) in
            func table(_ sql: String, rename: (inout [String: OracleValue]) -> Void = { _ in }) throws -> [[String: OracleValue]] {
                try Row.fetchAll(db, sql: sql).map { row in
                    var fields: [String: OracleValue] = [:]
                    for (column, value) in row { fields[column] = OracleValue.databaseValue(value) }
                    rename(&fields)
                    return fields
                }
            }
            let transactions = try table("""
                SELECT id, COALESCE(isParent, 0) AS is_parent, COALESCE(isChild, 0) AS is_child,
                       CASE WHEN COALESCE(isChild, 0) = 0 THEN NULL ELSE parent_id END AS parent_id,
                       acct AS account, category, amount, description AS payee, notes, date,
                       financial_id AS imported_id, error, imported_description AS imported_payee,
                       COALESCE(starting_balance_flag, 0) AS starting_balance_flag,
                       transferred_id AS transfer_id, cleared, COALESCE(reconciled, 0) AS reconciled,
                       COALESCE(tombstone, 0) AS tombstone, schedule
                FROM transactions
                """) { fields in
                if case .number(let day)? = fields["date"] {
                    let text = String(Int(day))
                    fields["date"] = .string("\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))")
                }
            }
            return (
                transactions,
                try table("SELECT id, name, transfer_acct, COALESCE(tombstone, 0) AS tombstone FROM payees"),
                try table("SELECT id, COALESCE(tombstone, 0) AS tombstone FROM rules")
            )
        }
        return BankSyncOracleState.canonical(
            transactions: transactions,
            payees: payees,
            rules: rules,
            baselineTransactionIDs: try ids(input["transactions"], "input.transactions"),
            baselinePayeeIDs: try ids(worldTables["payees"], "worldTables.payees")
        )
    }

    // MARK: Seeding

    private struct SeedRow: Sendable {
        let sql: String
        let values: [DatabaseValue]
    }

    /// Clears the starter rows of the seeded tables, then inserts the upstream rows as dumped.
    private static func seed(_ database: BudgetDatabase, tables: [String: Any], prefs: [String: Any]) async throws {
        var rows: [SeedRow] = []
        for table in seedTables {
            for (index, row) in try OracleJSON.objects(tables[table] ?? [], table).enumerated() {
                var row = row
                // The dump leaves out sort_order; keep the dumped order.
                if table == "transactions" { row["sort_order"] = Double(1000 - index) }
                let columns = row.keys.sorted()
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                rows.append(SeedRow(
                    sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
                    values: try columns.map { try databaseValue(row[$0] ?? NSNull(), column: "\(table).\($0)") }
                ))
            }
        }
        let queue = await database.queue
        let order = Array(seedTables.reversed())
        let insertions = rows
        let preferences = try prefs.map { (id: $0.key, value: try OracleJSON.string(prefs, $0.key)) }
        try await queue.write { db in
            for table in order {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for preference in preferences {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO preferences (id, value) VALUES (?, ?)",
                    arguments: [preference.id, preference.value]
                )
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
            if String(cString: number.objCType) == "d" { return number.doubleValue.databaseValue }
            return number.int64Value.databaseValue
        default:
            throw OracleReplayError.malformedFixture("unsupported value in \(column)")
        }
    }
}
