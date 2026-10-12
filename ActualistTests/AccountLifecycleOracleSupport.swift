import Foundation
import GRDB
@testable import Actualist

enum AccountLifecycleOracleError: Error {
    case malformedFixture(String)
    case unknownCase(String)
    case malformedReplay(String)
}

enum ReplayNormalizer {
    /// Message order is not compared. The oracle's raw CRDT order is recorded in its fixture.
    static func messages(_ messages: [ActualSyncDecodedMessage], aliases: [String: String] = [:]) -> OracleValue {
        .array(messages.map { message -> OracleValue in
            .object([
                "dataset": .string(message.dataset),
                "row": .string(aliases[message.row] ?? message.row),
                "column": .string(message.column),
                "value": parse(message.serializedValue),
            ])
        })
    }

    /// Production serializes typed values with a prefix: `0:` null, `N:` number, `S:` string.
    static func parse(_ serialized: String) -> OracleValue {
        if serialized == "0:" {
            return .null
        }
        if serialized.hasPrefix("N:"), let number = Double(serialized.dropFirst(2)) {
            return .number(number)
        }
        if serialized.hasPrefix("S:") {
            return .string(String(serialized.dropFirst(2)))
        }
        return .string(serialized)
    }
}

/// Oracle observations for every account-lifecycle case, plus the manifest's oracle-only list.
struct AccountLifecycleOracleFixture {
    let observedByCase: [String: [String: OracleValue]]
    let oracleOnlyCaseIDs: Set<String>

    static func load() throws -> AccountLifecycleOracleFixture {
        let root = try ParityOraclePin.fixtureURL("AccountLifecycle")
        let fixture = try jsonObject(root.appending(path: "account-lifecycle-oracle.json"))
        let manifest = try jsonObject(root.appending(path: "account-lifecycle-manifest.json"))

        guard let rawCases = fixture["cases"] as? [[String: Any]] else {
            throw AccountLifecycleOracleError.malformedFixture("cases")
        }
        var observedByCase: [String: [String: OracleValue]] = [:]
        for rawCase in rawCases {
            guard let id = rawCase["id"] as? String,
                  let observed = rawCase["observed"] as? [String: Any] else {
                throw AccountLifecycleOracleError.malformedFixture("observed")
            }
            observedByCase[id] = try observed.mapValues { try OracleValue(json: $0) }
        }

        let onlyEntries = manifest["oracleOnly"] as? [[String: Any]] ?? []
        let oracleOnly = Set(onlyEntries.compactMap { $0["id"] as? String })
        return AccountLifecycleOracleFixture(observedByCase: observedByCase, oracleOnlyCaseIDs: oracleOnly)
    }

    func observed(_ caseID: String) throws -> [String: OracleValue] {
        guard let observed = observedByCase[caseID] else {
            throw AccountLifecycleOracleError.unknownCase(caseID)
        }
        return observed
    }

    private static func jsonObject(_ url: URL) throws -> [String: Any] {
        guard let object = try OracleJSONFileCache.jsonObject(at: url) as? [String: Any] else {
            throw AccountLifecycleOracleError.malformedFixture(url.lastPathComponent)
        }
        return object
    }
}

/// A fresh SQLite budget seeded with the oracle's synthetic state, opened by production `BudgetDatabase`.
final class AccountLifecycleReplayBudget {
    static let budgetID = "budget"

    let directory: URL
    let url: URL
    let database: BudgetDatabase
    private var capturedCount = 0

    init(seeds: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AccountLifecycleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "db.sqlite")
        let setup = try DatabaseQueue(path: url.path)
        try setup.write { db in
            try db.execute(sql: ReplaySQL.schema)
            try db.execute(sql: seeds)
        }
        database = try BudgetDatabase(databaseURL: url, localNodeID: "account-lifecycle-replay")
    }

    /// Outbox messages appended since the previous capture, in commit order.
    func capturedMessages() async throws -> [ActualSyncDecodedMessage] {
        let all = try await database.pendingLocalSyncMessages(limit: 100_000).map(\.message)
        let fresh = Array(all.dropFirst(capturedCount))
        capturedCount = all.count
        return fresh
    }

    func rows(
        _ table: String,
        where clause: String = "",
        aliases: [String: String] = [:]
    ) throws -> [OracleValue] {
        let reader = try DatabaseQueue(path: url.path)
        return try reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM \(table)\(clause) ORDER BY id").map { row in
                var object: [String: OracleValue] = [:]
                for (column, value) in row {
                    var converted = OracleValue.databaseValue(value)
                    if column == "id", case .string(let id) = converted, let alias = aliases[id] {
                        converted = .string(alias)
                    }
                    object[column] = converted
                }
                return OracleValue.object(object)
            }
        }
    }

    func record(_ table: String, id: String, aliases: [String: String] = [:]) throws -> OracleValue {
        try rows(table, where: " WHERE id = '\(id)'", aliases: aliases).first ?? .null
    }

    func accountName(_ id: String) throws -> String {
        guard case .object(let fields) = try record("accounts", id: id),
              case .string(let name)? = fields["name"] else {
            throw AccountLifecycleOracleError.malformedReplay("account name for \(id)")
        }
        return name
    }

    /// Full-table snapshot keyed by the oracle's table names.
    func snapshot(aliases: [String: String] = [:]) throws -> OracleValue {
        .object([
            "accounts": .array(try rows("accounts", aliases: aliases)),
            "banks": .array(try rows("banks", aliases: aliases)),
            "payees": .array(try rows("payees", aliases: aliases)),
            "rules": .array(try rows("rules", aliases: aliases)),
            "scheduleDates": .array(try rows("schedules_next_date", aliases: aliases)),
            "schedules": .array(try rows("schedules", aliases: aliases)),
            "transactions": .array(try rows("transactions", aliases: aliases)),
        ])
    }

    func scheduleSnapshot() throws -> OracleValue {
        .object([
            "rules": .array(try rows("rules")),
            "scheduleDates": .array(try rows("schedules_next_date")),
            "schedules": .array(try rows("schedules")),
        ])
    }

    /// Maps the production-generated UUID of the posted scheduled transaction to the oracle's `id4`.
    func scheduledTransactionAliases() throws -> [String: String] {
        let reader = try DatabaseQueue(path: url.path)
        let ids = try reader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM transactions WHERE schedule = 'schedule-source' AND tombstone = 0")
        }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, "id4") })
    }

    /// Forces a schedule run by clearing the local `lastScheduleRun` day marker, as the oracle's force-run does.
    func clearScheduleDayMarker() throws {
        let metadata = directory.appending(path: "metadata.json")
        if FileManager.default.fileExists(atPath: metadata.path) {
            try FileManager.default.removeItem(at: metadata)
        }
    }
}

/// SQL seed helpers. Values come only from the oracle's synthetic inputs.
enum ReplaySQL {
    static let schema = """
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, offbudget INTEGER, closed INTEGER,
            tombstone INTEGER, sort_order INTEGER, account_id TEXT, bank TEXT,
            balance_current INTEGER, balance_available INTEGER, balance_limit INTEGER,
            account_sync_source TEXT, bank_sync_status TEXT, last_sync TEXT, account_group_id TEXT
        );
        CREATE TABLE banks (id TEXT PRIMARY KEY, name TEXT, bank_id TEXT, tombstone INTEGER);
        CREATE TABLE payees (
            id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, favorite INTEGER,
            learn_categories INTEGER, tombstone INTEGER
        );
        CREATE TABLE category_groups (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, is_income INTEGER, hidden INTEGER,
            tombstone INTEGER, sort_order INTEGER
        );
        CREATE TABLE categories (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, cat_group TEXT, is_income INTEGER,
            hidden INTEGER, tombstone INTEGER, sort_order INTEGER
        );
        CREATE TABLE transactions (
            id TEXT PRIMARY KEY, isParent INTEGER DEFAULT 0, isChild INTEGER DEFAULT 0,
            parent_id TEXT, acct TEXT, category TEXT, amount INTEGER, description TEXT,
            notes TEXT, date INTEGER, financial_id TEXT, transferred_id TEXT, sort_order REAL,
            tombstone INTEGER DEFAULT 0, cleared INTEGER DEFAULT 1, reconciled INTEGER DEFAULT 0,
            schedule TEXT, starting_balance_flag INTEGER DEFAULT 0, error TEXT
        );
        CREATE TABLE rules (
            id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
            conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules (
            id TEXT PRIMARY KEY, rule TEXT, name TEXT, active INTEGER,
            completed INTEGER DEFAULT 0, posts_transaction INTEGER DEFAULT 0,
            custom_upcoming_length TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules_next_date (
            id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER,
            local_next_date_ts INTEGER, base_next_date INTEGER, base_next_date_ts INTEGER,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
        INSERT INTO preferences VALUES ('upcomingScheduledTransactionLength', '7');
        CREATE TABLE messages_crdt (timestamp TEXT, dataset TEXT, row TEXT, column TEXT, value TEXT);
        CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT);
        CREATE TABLE zero_budgets (month INTEGER, category TEXT, amount INTEGER, carryover INTEGER);
        """

    static let bank = "INSERT INTO banks VALUES ('bank-1', 'Synthetic bank', 'synthetic-bank', 0);\n"

    static let hiddenCategory = """
        INSERT INTO category_groups VALUES ('group', 'Everyday', 0, 0, 0, 1);
        INSERT INTO categories VALUES ('hidden-category', 'Hidden category', 'group', 0, 1, 0, 2);

        """

    static let scheduleSeeds = """
        INSERT INTO rules VALUES ('id2', NULL, '[{"op":"is","field":"acct","value":"source"},{"op":"is","field":"amount","value":-775},{"op":"is","field":"date","value":"2026-09-27"}]', '[{"op":"link-schedule","value":"schedule-source"}]', 'and', 0);
        INSERT INTO schedules VALUES ('schedule-source', 'id2', 'Synthetic schedule', 0, 0, 1, NULL, 0, 0);
        INSERT INTO schedules_next_date VALUES ('id3', 'schedule-source', 20260927, 1790510400000, 20260927, 1790510400000, 0);

        """

    static func account(
        _ id: String,
        name: String,
        offBudget: Bool = false,
        closed: Bool = false,
        sortOrder: Int = 16384,
        bankLinked: Bool = false
    ) -> String {
        let link = bankLinked
            ? "'remote-account', 'bank-1', 1000, 1000, NULL, 'simpleFin', 'ok', 'synthetic-last-sync', NULL"
            : "NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL"
        return "INSERT INTO accounts VALUES ('\(id)', '\(name)', \(bit(offBudget)), \(bit(closed)), 0, \(sortOrder), \(link));\n"
    }

    static func payee(_ accountID: String) -> String {
        "INSERT INTO payees VALUES ('transfer-\(accountID)', '', '\(accountID)', 0, 1, 0);\n"
    }

    static func transaction(
        _ id: String,
        acct: String,
        amount: Int,
        category: String? = nil,
        parentID: String? = nil,
        isParent: Bool = false,
        isChild: Bool = false
    ) -> String {
        "INSERT INTO transactions VALUES ('\(id)', \(bit(isParent)), \(bit(isChild)), \(text(parentID)), '\(acct)', \(text(category)), \(amount), NULL, NULL, 20260927, NULL, NULL, 1790510400000, 0, 1, 0, NULL, 0, NULL);\n"
    }

    private static func text(_ value: String?) -> String {
        value.map { "'\($0)'" } ?? "NULL"
    }

    private static func bit(_ value: Bool) -> Int {
        value ? 1 : 0
    }
}
