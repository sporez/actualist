import Foundation
import GRDB
import Testing
@testable import Actualist

/// Untrusted budget files (portable import, server download) must not carry
/// Actualist bookkeeping, triggers, or stray databases into the local store.
@Suite @MainActor
struct UntrustedBudgetSanitizationTests {
    private let support = LocalFirstActualStoreTests()
    private static let outboxMarker = "SECRET-OUTBOX-MARKER-7f3a"
    private static let knownStorageID = "KNOWN-STORAGE-ID-0001"
    /// Tables the hostile fixture plants; the rule-based sanitiser must drop each.
    private static let strippedFixtureTables = [
        "kvcache", "kvcache_key", "actualist_action_log", "actualist_outbox",
        "actualist_local_migrations", "actualist_budget_identity", "actualist_sync_checkpoint"
    ]

    // MARK: - Fixtures

    /// A minimal valid budget plus everything an attacker could smuggle in.
    private func makeHostileDatabase(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE category_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, acct TEXT, date INTEGER, amount INTEGER
                );
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT, dataset TEXT,
                    row TEXT, column TEXT, value BLOB
                );
                INSERT INTO accounts VALUES ('checking', 'Checking');
                INSERT INTO category_groups VALUES ('group-1', 'Everyday');
                INSERT INTO categories VALUES ('groceries', 'Groceries');
                INSERT INTO transactions VALUES ('txn-1', 'checking', 20260901, -12345);
                CREATE VIEW v_transactions AS SELECT id, acct, date, amount FROM transactions;
                CREATE VIEW evil_view AS SELECT id FROM accounts;
                CREATE TABLE actualist_outbox (
                    timestamp TEXT PRIMARY KEY, dataset TEXT NOT NULL, row TEXT NOT NULL,
                    column TEXT NOT NULL, value TEXT NOT NULL, base_timestamp TEXT NOT NULL,
                    created_at TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
                    last_attempt_at TEXT, last_error TEXT
                );
                INSERT INTO actualist_outbox (timestamp, dataset, row, column, value, base_timestamp, created_at)
                    VALUES ('2026-09-01T00:00:00.000Z-0000-aaaaaaaaaaaaaaaa', 'accounts', 'checking',
                            'name', '\(Self.outboxMarker)', '', '2026-09-01');
                CREATE TABLE actualist_budget_identity (
                    id INTEGER PRIMARY KEY CHECK (id = 1), storage_id TEXT NOT NULL
                );
                INSERT INTO actualist_budget_identity VALUES (1, '\(Self.knownStorageID)');
                CREATE TABLE kvcache (key TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE kvcache_key (id INTEGER PRIMARY KEY, key REAL);
                INSERT INTO kvcache VALUES ('k', 'v');
                CREATE TABLE actualist_action_log (id TEXT PRIMARY KEY, summary TEXT);
                INSERT INTO actualist_action_log VALUES ('a1', 'logged');
                CREATE TABLE actualist_local_migrations (name TEXT PRIMARY KEY, applied_at TEXT);
                CREATE TABLE actualist_sync_checkpoint (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    last_synced_at REAL NOT NULL,
                    last_applied_message_count INTEGER NOT NULL,
                    last_uploaded_message_count INTEGER NOT NULL
                );
                INSERT INTO actualist_sync_checkpoint VALUES (1, 1790000000, 41, 7);
                CREATE TRIGGER wipe AFTER INSERT ON messages_crdt BEGIN DELETE FROM accounts; END;
                """)
        }
    }

    private func makeHostileDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "UntrustedSanitization-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        try makeHostileDatabase(at: url)
        return url
    }

    private struct SchemaSummary {
        let tables: Set<String>
        let views: Set<String>
        let triggers: Set<String>
    }

    private func schema(of url: URL) throws -> SchemaSummary {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { db in
            func names(_ type: String) throws -> Set<String> {
                Set(try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = ?",
                    arguments: [type]
                ))
            }
            return SchemaSummary(
                tables: try names("table"),
                views: try names("view"),
                triggers: try names("trigger")
            )
        }
    }

    private func expectSanitized(_ url: URL) throws {
        let summary = try schema(of: url)
        for stripped in Self.strippedFixtureTables {
            #expect(!summary.tables.contains(stripped), "\(stripped) survived")
        }
        #expect(summary.triggers.isEmpty)
        #expect(summary.views.contains("v_transactions"))
        #expect(!summary.views.contains("evil_view"))
        #expect(summary.tables.isSuperset(of: ["accounts", "transactions", "messages_crdt"]))
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data(Self.outboxMarker.utf8)) == nil)
        #expect(bytes.range(of: Data(Self.knownStorageID.utf8)) == nil)
    }

    private func makeDownloadFixture(
        entries: [(String, Data)]
    ) throws -> (fileManager: BudgetFileManager, stagingURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "UntrustedDownload-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let stagingURL = try fileManager.prepareDownloadStaging(fileID: "file-1")
        try support.makeArchive(at: stagingURL, entries: entries)
        return (fileManager, stagingURL)
    }

    // MARK: - Sanitization

    @Test func serverDownloadDropsBookkeepingTriggersAndGetsAFreshStorageID() async throws {
        let database = try Data(contentsOf: try makeHostileDatabaseURL())
        let (fileManager, stagingURL) = try makeDownloadFixture(entries: [("db.sqlite", database)])

        let imported = try await fileManager.importBudgetZip(
            at: stagingURL,
            remoteFile: support.testRemoteFile(),
            metadata: support.testBudgetMetadata()
        )

        try expectSanitized(imported)
        let opened = try BudgetDatabase(databaseURL: imported)
        let storageID = try await opened.fetchBudgetModeIdentity().storageID
        #expect(storageID != Self.knownStorageID)
        #expect(try await opened.pendingLocalSyncMessageCount() == 0)
    }

    @Test func syncCheckpointDoesNotSurviveImportOrExport() async throws {
        let imported = try makeHostileDatabaseURL()
        try BudgetDatabase.sanitizeUntrustedDatabase(at: imported)
        #expect(!(try schema(of: imported)).tables.contains("actualist_sync_checkpoint"))

        let source = try makeHostileDatabaseURL()
        let database = try BudgetDatabase(databaseURL: source)
        let snapshotURL = source.deletingLastPathComponent().appending(path: "snapshot.sqlite")
        try await database.writePortableSnapshot(to: snapshotURL)
        #expect(!(try schema(of: snapshotURL)).tables.contains("actualist_sync_checkpoint"))
    }

    @Test func portableValidationDropsBookkeepingTriggersAndViewsThatAreNotMirrors() throws {
        let database = try Data(contentsOf: try makeHostileDatabaseURL())
        let work = FileManager.default.temporaryDirectory
            .appending(path: "UntrustedPortable-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archiveURL = work.appending(path: "portable.zip")
        let metadata = try JSONSerialization.data(withJSONObject: ["id": "src", "budgetName": "Hostile"])
        try support.makeArchive(at: archiveURL, entries: [("db.sqlite", database), ("metadata.json", metadata)])

        let staging = work.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let validated = try PortableBudgetArchive().validate(archiveAt: archiveURL, stagingDirectory: staging)

        try expectSanitized(validated.databaseURL)
    }

    @Test func exportDropsTriggersAndLeavesNoStrippedBytesInTheUpload() async throws {
        let source = try makeHostileDatabaseURL()
        let database = try BudgetDatabase(databaseURL: source)
        let snapshotURL = source.deletingLastPathComponent().appending(path: "snapshot.sqlite")

        try await database.writePortableSnapshot(to: snapshotURL)

        let summary = try schema(of: snapshotURL)
        #expect(summary.triggers.isEmpty)
        #expect(summary.views.contains("v_transactions"))
        for stripped in Self.strippedFixtureTables {
            #expect(!summary.tables.contains(stripped))
        }
        let bytes = try Data(contentsOf: snapshotURL)
        #expect(bytes.range(of: Data(Self.outboxMarker.utf8)) == nil)
    }

    /// Every `sqlite_master` object an opened database creates for itself
    /// (pending-new, Bank Sync last run, the timestamp index, outbox, action
    /// log, checkpoint) must be stripped by rule, not by a hand-kept list.
    private func actualistObjectNames(of url: URL) throws -> [String] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master")
                .filter { $0.lowercased().hasPrefix(ActualSyncDatasetPolicy.localTablePrefix) }
        }
    }

    @Test func exportOfAFullyExercisedDatabaseCarriesNoActualistObjects() async throws {
        let source = try makeHostileDatabaseURL()
        let database = try BudgetDatabase(databaseURL: source)
        try await database.saveBankSyncLastRun(
            BankSyncLastRun(finishedAt: Date(), trigger: .manual, summary: "done")
        )
        #expect(!(try actualistObjectNames(of: source)).isEmpty)
        let snapshotURL = source.deletingLastPathComponent().appending(path: "snapshot.sqlite")

        try await database.writePortableSnapshot(to: snapshotURL)

        #expect(try actualistObjectNames(of: snapshotURL) == [])
    }

    @Test func serverDownloadSanitisationStripsEveryActualistObject() async throws {
        let source = try makeHostileDatabaseURL()
        let database = try BudgetDatabase(databaseURL: source)
        try await database.saveBankSyncLastRun(
            BankSyncLastRun(finishedAt: Date(), trigger: .manual, summary: "done")
        )

        try BudgetDatabase.sanitizeUntrustedDatabase(at: source)

        #expect(try actualistObjectNames(of: source) == [])
        let queue = try DatabaseQueue(path: source.path)
        let kvcache = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name LIKE 'kvcache%'")
        }
        #expect(kvcache.isEmpty)
    }

    // MARK: - Database selection

    private func tinyValidDatabase(marker: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "UntrustedPick-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE transactions (id TEXT PRIMARY KEY, acct TEXT, date INTEGER, amount INTEGER);
                CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE category_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                INSERT INTO accounts VALUES ('\(marker)', '\(marker)');
                """)
        }
        return try Data(contentsOf: url)
    }

    private func firstAccountID(at url: URL) throws -> String? {
        try DatabaseQueue(path: url.path).read { db in
            try String.fetchOne(db, sql: "SELECT id FROM accounts")
        }
    }

    @Test func siblingSqliteFileDoesNotShadowDbSqlite() async throws {
        let (fileManager, stagingURL) = try makeDownloadFixture(entries: [
            ("a.sqlite", try tinyValidDatabase(marker: "wrong")),
            ("db.sqlite", try tinyValidDatabase(marker: "right"))
        ])
        let imported = try await fileManager.importBudgetZip(
            at: stagingURL, remoteFile: support.testRemoteFile(), metadata: support.testBudgetMetadata()
        )
        #expect(try firstAccountID(at: imported) == "right")
    }

    @Test func onlyANonDbSqliteNameIsRejected() async throws {
        let (fileManager, stagingURL) = try makeDownloadFixture(entries: [
            ("x.sqlite", try tinyValidDatabase(marker: "x"))
        ])
        await #expect(throws: LocalFirstError.missingImportedDatabase) {
            try await fileManager.importBudgetZip(
                at: stagingURL, remoteFile: support.testRemoteFile(), metadata: support.testBudgetMetadata()
            )
        }
    }

    @Test func twoNestedDbSqliteFilesAreRejected() async throws {
        let (fileManager, stagingURL) = try makeDownloadFixture(entries: [
            ("one/db.sqlite", try tinyValidDatabase(marker: "one")),
            ("two/db.sqlite", try tinyValidDatabase(marker: "two"))
        ])
        await #expect(throws: LocalFirstError.invalidDownloadedBudget) {
            try await fileManager.importBudgetZip(
                at: stagingURL, remoteFile: support.testRemoteFile(), metadata: support.testBudgetMetadata()
            )
        }
    }

    @Test func rootDbSqlitePreferredOverNested() async throws {
        let (fileManager, stagingURL) = try makeDownloadFixture(entries: [
            ("nested/db.sqlite", try tinyValidDatabase(marker: "nested")),
            ("db.sqlite", try tinyValidDatabase(marker: "root"))
        ])
        let imported = try await fileManager.importBudgetZip(
            at: stagingURL, remoteFile: support.testRemoteFile(), metadata: support.testBudgetMetadata()
        )
        #expect(try firstAccountID(at: imported) == "root")
    }

    @Test func singleNestedDbSqliteIsAccepted() async throws {
        let (fileManager, stagingURL) = try makeDownloadFixture(entries: [
            ("nested/db.sqlite", try tinyValidDatabase(marker: "nested"))
        ])
        let imported = try await fileManager.importBudgetZip(
            at: stagingURL, remoteFile: support.testRemoteFile(), metadata: support.testBudgetMetadata()
        )
        #expect(try firstAccountID(at: imported) == "nested")
    }
}
