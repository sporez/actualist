import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import Actualist

/// Portable ZIP validate and export-snapshot coverage.
///
/// These tests materialize the declarative cases from
/// `ActualistTests/Fixtures/Portability/Archive/portability-archive-cases.json`
/// against a synthetic SQLite seed. No demo or user budget bytes, no server,
/// and no download/reimport (`importBudgetZip` / `reimportBudget`) assertions:
/// those stay in `LocalFirstActualStoreStorageTransportTests`.
@Suite struct PortableBudgetArchiveTests {
    private let sourceIdentity = "cloud-file-1"
    private let tokenSecret = "sync-token-secret-value"
    private let keySecret = "encrypt-key-secret-value"

    // MARK: - Accept cases (root-co-located-pair, nested-co-located-pair)

    @Test func acceptsRootCoLocatedPair() throws {
        try assertAcceptsPair(layout: .root)
    }

    @Test func acceptsNestedCoLocatedPair() throws {
        try assertAcceptsPair(layout: .nested)
    }

    @Test func acceptedPairDiscardsUnrelatedArchiveFiles() throws {
        let suite = try SuiteFixture(label: "extra-files")
        let archiveURL = suite.directory.appending(path: "extra.zip")
        try Self.writeZip(
            at: archiveURL,
            files: try suite.pairFiles(layout: .root) + [("notes.txt", Data("unrelated".utf8))]
        )

        let validated = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)

        let validatedDirectory = validated.databaseURL.deletingLastPathComponent()
        let names = Set(
            try FileManager.default.contentsOfDirectory(atPath: validatedDirectory.path)
        )
        #expect(names == ["db.sqlite", "metadata.json"])
    }

    @Test func acceptsKnownMigrationWatermarkAndRejectsUnknownSchema() throws {
        let known = [BudgetDatabase.accountGroupsMigrationID, 1_548_957_970_627]
        let withKnownWatermark = try Self.makeSeedDatabaseURL(migrationIDs: known)
        try assertAccepts(databaseURL: withKnownWatermark, label: "known-migrations")

        let withUnknownWatermark = try Self.makeSeedDatabaseURL(
            migrationIDs: known + [999_999_999_999]
        )
        let suite = SuiteFixture(label: "unknown-migrations")
        let archiveURL = try suite.makeArchive(databaseURL: withUnknownWatermark)
        #expect(
            throws: PortableBudgetArchiveError(stage: .beforeInstall, reason: .unsupportedSchema)
        ) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
    }

    // MARK: - Reject-before-install cases

    @Test func rejectsMissingDatabaseBeforeInstall() throws {
        try assertRejectBeforeInstall(
            caseID: "missing-database",
            files: [("metadata.json", try Self.metadataJSON())],
            expected: PortableBudgetArchiveError(stage: .beforeInstall, reason: .missingDatabase)
        )
    }

    @Test func rejectsMissingMetadataBeforeInstall() throws {
        let seed = try Self.makeSeedDatabaseURL()
        try assertRejectBeforeInstall(
            caseID: "missing-metadata",
            files: [("db.sqlite", try Data(contentsOf: seed))],
            expected: PortableBudgetArchiveError(stage: .beforeInstall, reason: .missingMetadata)
        )
    }

    @Test func rejectsSplitDirectoryPairBeforeInstall() throws {
        let seed = try Self.makeSeedDatabaseURL()
        try assertRejectBeforeInstall(
            caseID: "split-directory-pair",
            files: [
                ("one/db.sqlite", try Data(contentsOf: seed)),
                ("two/metadata.json", try Self.metadataJSON())
            ],
            expected: PortableBudgetArchiveError(stage: .beforeInstall, reason: .splitDirectories)
        )
    }

    @Test func rejectsDuplicateDatabaseCandidatesBeforeInstall() throws {
        let seed = try Self.makeSeedDatabaseURL()
        try assertRejectBeforeInstall(
            caseID: "duplicate-database-candidates",
            files: [
                ("db.sqlite", try Data(contentsOf: seed)),
                ("metadata.json", try Self.metadataJSON()),
                ("other/db.sqlite", try Data(contentsOf: seed))
            ],
            expected: PortableBudgetArchiveError(stage: .beforeInstall, reason: .ambiguous)
        )
    }

    @Test func rejectsDuplicateRootPairBeforeInstall() throws {
        let seed = try Self.makeSeedDatabaseURL()
        try assertRejectBeforeInstall(
            caseID: "duplicate-root-pair",
            files: [
                ("db.sqlite", try Data(contentsOf: seed)),
                ("metadata.json", try Self.metadataJSON()),
                ("copy/db.sqlite", try Data(contentsOf: seed)),
                ("copy/metadata.json", try Self.metadataJSON())
            ],
            expected: PortableBudgetArchiveError(stage: .beforeInstall, reason: .ambiguous)
        )
    }

    @Test func rejectsTruncatedArchiveBeforeInstall() throws {
        let seed = try Self.makeSeedDatabaseURL()
        let directory = try makeTempDirectory("truncated")
        let archiveURL = directory.appending(path: "truncated.zip")
        try Self.writeZip(
            at: archiveURL,
            files: [("db.sqlite", try Data(contentsOf: seed)), ("metadata.json", try Self.metadataJSON())]
        )
        let data = try Data(contentsOf: archiveURL)
        try data.prefix(data.count * 3 / 4).write(to: archiveURL)

        let suite = SuiteFixture(existingDirectory: directory)
        #expect(
            throws: PortableBudgetArchiveError(stage: .beforeInstall, reason: .truncated)
        ) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
    }

    @Test func rejectsNonSQLiteDatabaseBeforeInstall() throws {
        let directory = try makeTempDirectory("not-sqlite")
        let fake = directory.appending(path: "fake.sqlite")
        try Data("not a database".utf8).write(to: fake)
        try assertRejectBeforeInstall(
            caseID: "integrity",
            files: [("db.sqlite", try Data(contentsOf: fake)), ("metadata.json", try Self.metadataJSON())],
            expected: PortableBudgetArchiveError(stage: .beforeInstall, reason: .integrity)
        )
    }

    @Test func rejectsChecksumMismatchBeforeInstall() throws {
        let seed = try Self.makeSeedDatabaseURL()
        let directory = try makeTempDirectory("checksum")
        let archiveURL = directory.appending(path: "corrupt.zip")
        // Stored (uncompressed) entries keep payload bytes findable so a single
        // flipped byte breaks only the recorded checksum, not the zip structure.
        try Self.writeZip(
            at: archiveURL,
            files: [("db.sqlite", try Data(contentsOf: seed)), ("metadata.json", try Self.metadataJSON())]
        )
        var data = try Data(contentsOf: archiveURL)
        let marker = Data("SQLite format 3".utf8)
        let payload = try #require(
            data.firstRange(of: marker),
            "Archive payload did not contain the SQLite header marker"
        )
        data[payload.lowerBound + 100] ^= 0xFF
        try data.write(to: archiveURL)

        let suite = SuiteFixture(existingDirectory: directory)
        #expect(
            throws: PortableBudgetArchiveError(stage: .beforeInstall, reason: .checksumMismatch)
        ) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
    }

    // MARK: - Reject-before-extraction cases

    @Test func rejectsParentTraversalEntryBeforeExtraction() throws {
        try assertRejectBeforeExtraction(
            caseID: "parent-traversal-entry",
            files: [],
            symlinks: [],
            extraFiles: [("../outside.txt", Data("escape".utf8))],
            expected: PortableBudgetArchiveError(stage: .beforeExtraction, reason: .unsafePath)
        )
    }

    @Test func rejectsAbsoluteEntryBeforeExtraction() throws {
        try assertRejectBeforeExtraction(
            caseID: "absolute-entry",
            files: [],
            symlinks: [],
            extraFiles: [("/outside.txt", Data("escape".utf8))],
            expected: PortableBudgetArchiveError(stage: .beforeExtraction, reason: .unsafePath)
        )
    }

    @Test func rejectsBackslashTraversalEntryBeforeExtraction() throws {
        try assertRejectBeforeExtraction(
            caseID: "backslash-traversal-entry",
            files: [],
            symlinks: [],
            extraFiles: [("..\\outside.txt", Data("escape".utf8))],
            expected: PortableBudgetArchiveError(stage: .beforeExtraction, reason: .unsafePath)
        )
    }

    @Test func rejectsSymbolicLinkEntryBeforeExtraction() throws {
        try assertRejectBeforeExtraction(
            caseID: "symbolic-link-entry",
            files: [],
            symlinks: [("bundle/link", "/etc/passwd")],
            extraFiles: [],
            expected: PortableBudgetArchiveError(stage: .beforeExtraction, reason: .symbolicLink)
        )
    }

    // MARK: - Resource limits

    @Test func rejectsArchivesOverTheCompressedLimitBeforeExtraction() throws {
        let directory = try makeTempDirectory("compressed-limit")
        let archiveURL = directory.appending(path: "large.zip")
        try Data(repeating: 0x41, count: 4_096).write(to: archiveURL)

        let limits = Self.standardLimits(compressedBudgetBytes: 1_024)
        let suite = SuiteFixture(existingDirectory: directory, limits: limits)
        #expect(
            throws: PortableBudgetArchiveError(stage: .beforeExtraction, reason: .resourceLimit)
        ) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
    }

    @Test func rejectsArchivesOverTheExpandedLimitBeforeExtraction() throws {
        let seed = try Self.makeSeedDatabaseURL()
        let limits = Self.standardLimits(expandedBudgetBytes: 512)
        let suite = SuiteFixture(label: "expanded-limit", limits: limits)
        let archiveURL = try suite.makeArchive(
            databaseURL: seed,
            entries: [("bundle/db.sqlite", try Data(contentsOf: seed)), ("bundle/metadata.json", try Self.metadataJSON())]
        )

        #expect(
            throws: PortableBudgetArchiveError(stage: .beforeExtraction, reason: .resourceLimit)
        ) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
    }

    @Test func rejectsArchivesOverTheEntryCountLimitBeforeExtraction() throws {
        let seed = try Self.makeSeedDatabaseURL()
        let limits = Self.standardLimits(entryCount: 1)
        let suite = SuiteFixture(label: "entry-count", limits: limits)
        let archiveURL = try suite.makeArchive(
            databaseURL: seed,
            entries: [
                ("db.sqlite", try Data(contentsOf: seed)),
                ("metadata.json", try Self.metadataJSON()),
                ("notes.txt", Data("extra".utf8))
            ]
        )

        #expect(
            throws: PortableBudgetArchiveError(stage: .beforeExtraction, reason: .resourceLimit)
        ) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
    }

    // MARK: - Metadata sanitization

    @Test func rejectedArchivesKeepMalformedMetadataOut() throws {
        try assertRejectBeforeInstall(
            caseID: "malformed-metadata",
            files: [("db.sqlite", try Data(contentsOf: Self.makeSeedDatabaseURL())), ("metadata.json", Data("not json".utf8))],
            expected: PortableBudgetArchiveError(stage: .beforeInstall, reason: .malformedMetadata)
        )
    }

    @Test func rejectedArchivesKeepMetadataWithoutBudgetNameOut() throws {
        let nameless = try JSONSerialization.data(
            withJSONObject: ["id": sourceIdentity],
            options: [.sortedKeys]
        )
        try assertRejectBeforeInstall(
            caseID: "malformed-metadata-name",
            files: [("db.sqlite", try Data(contentsOf: Self.makeSeedDatabaseURL())), ("metadata.json", nameless)],
            expected: PortableBudgetArchiveError(stage: .beforeInstall, reason: .malformedMetadata)
        )
    }

    @Test func rejectsOversizedMetadataBeforeInstall() throws {
        let suite = SuiteFixture(
            label: "oversized-metadata",
            limits: Self.standardLimits(),
            maximumMetadataBytes: 32
        )
        let archiveURL = try suite.makeArchive(databaseURL: Self.makeSeedDatabaseURL())

        #expect(
            throws: PortableBudgetArchiveError(stage: .beforeInstall, reason: .oversizedMetadata)
        ) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
    }

    @Test func validationSanitizesEmbeddedMetadataAndRegeneratesIdentity() throws {
        // Identity generator collides with the embedded cloud file id on
        // purpose: the archive identity must still not become the source id.
        let suite = SuiteFixture(
            label: "sanitized",
            identityGenerator: { [sourceIdentity] in sourceIdentity }
        )
        let archiveURL = try suite.makeArchive(databaseURL: Self.makeSeedDatabaseURL())

        let validated = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)

        #expect(validated.metadata.resetClock == true)
        #expect(validated.metadata.id != sourceIdentity)
        #expect(!validated.metadata.id.isEmpty)
        #expect(validated.metadata.budgetName == "Portable Test Budget")

        let written = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: validated.metadataURL)
        ) as? [String: Any]
        #expect(written?["resetClock"] as? Bool == true)
        #expect(written?["id"] as? String != sourceIdentity)
        #expect(Set((written ?? [:]).keys) == Set(PortableBudgetMetadata.archivedKeys))
        let raw = try String(contentsOf: validated.metadataURL, encoding: .utf8)
        for forbidden in [sourceIdentity, "group-secret-1", keySecret, "password-secret", "/Users/"] {
            #expect(!raw.contains(forbidden))
        }
    }

    // MARK: - Export

    @Test func exportProducesRootPairWithDomainRowsAndStrippedLocalTables() async throws {
        let seed = try Self.makeSeedDatabaseURL()
        let database = try BudgetDatabase(databaseURL: seed)
        let directory = try makeTempDirectory("export")
        let archiveURL = directory.appending(path: "export.zip")
        let archive = PortableBudgetArchive(limits: Self.standardLimits())

        let metadata = try await archive.export(
            database: database,
            budgetName: "Export Test",
            sourceIdentity: sourceIdentity,
            to: archiveURL
        )

        #expect(metadata.resetClock == true)
        #expect(metadata.id != sourceIdentity)
        #expect(metadata.budgetName == "Export Test")

        let outDirectory = try makeTempDirectory("export-out")
        let readArchive = try Archive(url: archiveURL, accessMode: .read)
        var entryNames: [String] = []
        for entry in readArchive {
            entryNames.append(entry.path)
            try readArchive.extract(entry, to: outDirectory.appending(path: entry.path))
        }
        #expect(Set(entryNames) == ["db.sqlite", "metadata.json"])

        let extractedDatabaseURL = outDirectory.appending(path: "db.sqlite")
        let extractedMetadataURL = outDirectory.appending(path: "metadata.json")
        let snapshot = try DatabaseQueue(path: extractedDatabaseURL.path)
        try await snapshot.read { db in
            let tables = Set(
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            )
            #expect(tables.isSuperset(of: ["accounts", "category_groups", "categories", "transactions"]))
            #expect(tables.filter { $0.hasPrefix("actualist_") }.isEmpty)
            // Upstream's Actual-format import runs DELETE FROM kvcache/kvcache_key.
            #expect(tables.isSuperset(of: ["kvcache", "kvcache_key"]))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kvcache") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kvcache_key") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM categories") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 1)
        }

        // Secrets that only lived in stripped cache tables must not survive in
        // the snapshot bytes.
        let rawSnapshot = try String(decoding: Data(contentsOf: extractedDatabaseURL), as: UTF8.self)
        #expect(!rawSnapshot.contains(tokenSecret))
        #expect(!rawSnapshot.contains(keySecret))

        let written = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: extractedMetadataURL)
        ) as? [String: Any]
        #expect(Set((written ?? [:]).keys) == Set(PortableBudgetMetadata.archivedKeys))
        #expect(written?["resetClock"] as? Bool == true)
        #expect(written?["id"] as? String != sourceIdentity)
        #expect(written?["budgetName"] as? String == "Export Test")
        let rawMetadata = try String(decoding: Data(contentsOf: extractedMetadataURL), as: UTF8.self)
        for forbidden in [sourceIdentity, "group-secret-1", keySecret, "password-secret", "/Users/"] {
            #expect(!rawMetadata.contains(forbidden))
        }
    }

    @Test func exportNeverReusesACollidingSourceIdentity() async throws {
        let seed = try Self.makeSeedDatabaseURL()
        let database = try BudgetDatabase(databaseURL: seed)
        let directory = try makeTempDirectory("export-collision")
        let archiveURL = directory.appending(path: "export.zip")
        let archive = PortableBudgetArchive(
            limits: Self.standardLimits(),
            identityGenerator: { [sourceIdentity] in sourceIdentity }
        )

        let metadata = try await archive.export(
            database: database,
            budgetName: "Export Test",
            sourceIdentity: sourceIdentity,
            to: archiveURL
        )

        #expect(metadata.id != sourceIdentity)
        #expect(!metadata.id.isEmpty)
    }

    // MARK: - Fixtures

    private enum PairLayout {
        case root
        case nested
    }

    /// Per-case staging environment. Fresh directories keep failure-cleanup
    /// assertions independent between tests.
    private struct SuiteFixture {
        let directory: URL
        let staging: URL
        let archive: PortableBudgetArchive

        init(
            label: String,
            limits: LocalFirstResourceLimits = PortableBudgetArchiveTests.standardLimits(),
            maximumMetadataBytes: Int = PortableBudgetArchive.defaultMaximumMetadataBytes,
            identityGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
        ) {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "PortableArchive-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            directory = root
            staging = root.appending(path: "staging", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            archive = PortableBudgetArchive(
                limits: limits,
                maximumMetadataBytes: maximumMetadataBytes,
                identityGenerator: identityGenerator
            )
        }

        init(existingDirectory: URL, limits: LocalFirstResourceLimits = PortableBudgetArchiveTests.standardLimits()) {
            directory = existingDirectory
            staging = existingDirectory.appending(path: "staging", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            archive = PortableBudgetArchive(limits: limits)
        }

        func pairFiles(layout: PairLayout) throws -> [(String, Data)] {
            let seed = try PortableBudgetArchiveTests.makeSeedDatabaseURL()
            let database = try Data(contentsOf: seed)
            let metadata = try PortableBudgetArchiveTests.metadataJSON()
            switch layout {
            case .root:
                return [("db.sqlite", database), ("metadata.json", metadata)]
            case .nested:
                return [("bundle/db.sqlite", database), ("bundle/metadata.json", metadata)]
            }
        }

        func makeArchive(
            databaseURL: URL,
            entries: [(String, Data)]? = nil
        ) throws -> URL {
            let archiveURL = directory.appending(path: "case.zip")
            try PortableBudgetArchiveTests.writeZip(
                at: archiveURL,
                files: entries ?? [
                    ("db.sqlite", try Data(contentsOf: databaseURL)),
                    ("metadata.json", try PortableBudgetArchiveTests.metadataJSON())
                ]
            )
            return archiveURL
        }
    }

    private static func standardLimits(
        compressedBudgetBytes: UInt64 = 4 * 1_024 * 1_024,
        expandedBudgetBytes: UInt64 = 8 * 1_024 * 1_024,
        entryCount: Int = 100
    ) -> LocalFirstResourceLimits {
        LocalFirstResourceLimits(
            maximumCompressedBudgetBytes: compressedBudgetBytes,
            maximumExpandedBudgetBytes: expandedBudgetBytes,
            maximumArchiveEntryBytes: 8 * 1_024 * 1_024,
            maximumArchiveEntryCount: entryCount,
            maximumArchivePathDepth: 16,
            minimumFreeDiskReserveBytes: 0,
            maximumSyncResponseBytes: 1_024
        )
    }

    private func assertAcceptsPair(layout: PairLayout) throws {
        let suite = SuiteFixture(label: "accept-\(layout == .root ? "root" : "nested")")
        let archiveURL = try suite.makeArchive(databaseURL: Self.makeSeedDatabaseURL(), entries: try suite.pairFiles(layout: layout))

        let validated = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)

        #expect(FileManager.default.fileExists(atPath: validated.databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: validated.metadataURL.path))
        #expect(validated.databaseURL.deletingLastPathComponent()
            == validated.metadataURL.deletingLastPathComponent())
        #expect(validated.metadata.resetClock == true)
        #expect(validated.metadata.id != sourceIdentity)
        #expect(validated.metadata.budgetName == "Portable Test Budget")
    }

    private func assertAccepts(databaseURL: URL, label: String) throws {
        let suite = SuiteFixture(label: "accept-\(label)")
        let archiveURL = try suite.makeArchive(databaseURL: databaseURL)

        let validated = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)

        #expect(FileManager.default.fileExists(atPath: validated.databaseURL.path))
        #expect(validated.metadata.resetClock == true)
    }

    private func assertRejectBeforeInstall(
        caseID: String,
        files: [(String, Data)],
        expected: PortableBudgetArchiveError
    ) throws {
        let suite = SuiteFixture(label: caseID)
        let archiveURL = try suite.makeArchive(databaseURL: Self.makeSeedDatabaseURL(), entries: files)

        #expect(throws: expected) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
    }

    private func assertRejectBeforeExtraction(
        caseID: String,
        files: [(String, Data)],
        symlinks: [(String, String)],
        extraFiles: [(String, Data)],
        expected: PortableBudgetArchiveError
    ) throws {
        let suite = SuiteFixture(label: caseID)
        let archiveURL = suite.directory.appending(path: "unsafe.zip")
        try Self.writeZip(
            at: archiveURL,
            files: try suite.pairFiles(layout: .root) + extraFiles,
            symlinks: symlinks
        )

        #expect(throws: expected) {
            _ = try suite.archive.validate(archiveAt: archiveURL, stagingDirectory: suite.staging)
        }
        try assertNoPartialInstall(staging: suite.staging)
        // Nothing may escape the staging root, even if extraction never ran.
        let escaped = try FileManager.default.contentsOfDirectory(atPath: suite.directory.path)
            .filter { $0 == "outside.txt" }
        #expect(escaped.isEmpty)
    }

    private func assertNoPartialInstall(staging: URL) throws {
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        #expect(leftovers.isEmpty, "Failed validation must not leave staged work behind")
    }

    private func makeTempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PortableArchive-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Synthetic seed with Actual-like domain tables plus the local-only
    /// tables a portable snapshot must strip. Values are synthetic; no demo or
    /// user budget bytes.
    private static func makeSeedDatabaseURL(migrationIDs: [Int64]? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PortableArchive-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    offbudget INTEGER,
                    closed INTEGER,
                    tombstone INTEGER,
                    sort_order INTEGER
                );
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    is_income INTEGER,
                    hidden INTEGER,
                    tombstone INTEGER,
                    sort_order INTEGER
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    cat_group TEXT,
                    is_income INTEGER,
                    hidden INTEGER,
                    tombstone INTEGER,
                    sort_order INTEGER
                );
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    date INTEGER,
                    amount INTEGER,
                    category TEXT,
                    tombstone INTEGER
                );
                CREATE TABLE messages_crdt (
                    timestamp TEXT,
                    dataset TEXT,
                    row TEXT,
                    column TEXT,
                    value TEXT
                );
                CREATE TABLE kvcache (key TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE kvcache_key (key TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE actualist_action_log (
                    id INTEGER PRIMARY KEY,
                    action TEXT
                );
                CREATE TABLE actualist_outbox (
                    id INTEGER PRIMARY KEY,
                    payload TEXT
                );
                INSERT INTO accounts VALUES ('checking', 'Checking', 0, 0, 0, 1);
                INSERT INTO category_groups VALUES ('group-1', 'Everyday', 0, 0, 0, 1);
                INSERT INTO categories VALUES ('groceries', 'Groceries', 'group-1', 0, 0, 0, 1);
                INSERT INTO transactions VALUES ('txn-1', 'checking', 20260901, -12345, 'groceries', 0);
                INSERT INTO kvcache VALUES ('server-tokens', '{"token":"sync-token-secret-value"}');
                INSERT INTO kvcache_key VALUES ('file-key', 'encrypt-key-secret-value');
                INSERT INTO actualist_action_log VALUES (1, 'spentMoney');
                INSERT INTO actualist_outbox VALUES (1, 'pending-crdt-message');
                """)
            if let migrationIDs {
                try db.execute(sql: "CREATE TABLE __migrations__ (id INTEGER PRIMARY KEY)")
                for id in migrationIDs {
                    try db.execute(
                        sql: "INSERT INTO __migrations__ (id) VALUES (?)",
                        arguments: [id]
                    )
                }
            }
        }
        return url
    }

    private static func metadataJSON() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "id": "cloud-file-1",
                "budgetName": "Portable Test Budget",
                "cloudFileId": "cloud-file-1",
                "groupId": "group-secret-1",
                "encryptKeyId": "encrypt-key-secret-value",
                "password": "password-secret",
                "dataDir": "/Users/someone/Library/budgets/one"
            ],
            options: [.sortedKeys]
        )
    }

    private static func writeZip(
        at url: URL,
        files: [(String, Data)],
        symlinks: [(String, String)] = []
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .none
            ) { position, size in
                // ZIPFoundation requests the payload in write-sized chunks.
                // Returning more than the requested slice re-emits the whole
                // payload per chunk and corrupts the stored CRC for entries
                // larger than the 16 KiB write chunk.
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
        for (path, target) in symlinks {
            let targetData = Data(target.utf8)
            try archive.addEntry(
                with: path,
                type: .symlink,
                uncompressedSize: Int64(targetData.count)
            ) { _, _ in targetData }
        }
    }
}
