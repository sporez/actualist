import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    func makeBudgetMonth(
        toBudget: Int,
        groups: [BudgetMonthCategoryGroup] = []
    ) -> BudgetMonth {
        BudgetMonth(
            month: "2026-07",
            incomeAvailable: 0,
            lastMonthOverspent: 0,
            forNextMonth: 0,
            totalBudgeted: 0,
            toBudget: toBudget,
            fromLastMonth: 0,
            totalIncome: 0,
            totalSpent: 0,
            totalBalance: 0,
            categoryGroups: groups
        )
    }

    func makeGroup(
        id: String,
        isIncome: Bool,
        categories: [BudgetMonthCategory]
    ) -> BudgetMonthCategoryGroup {
        BudgetMonthCategoryGroup(
            id: id,
            name: id,
            isIncome: isIncome,
            hidden: false,
            budgeted: 0,
            spent: 0,
            balance: 0,
            categories: categories
        )
    }

    func makeCategory(
        id: String,
        balance: Int,
        hidden: Bool = false
    ) -> BudgetMonthCategory {
        BudgetMonthCategory(
            id: id,
            name: id,
            isIncome: false,
            hidden: hidden,
            groupID: "group",
            budgeted: 0,
            spent: 0,
            balance: balance,
            carryover: false
        )
    }

    func testResourceLimits(
        maximumCompressedBudgetBytes: UInt64 = 1_024,
        maximumExpandedBudgetBytes: UInt64 = 1_024,
        maximumArchiveEntryBytes: UInt64 = 1_024,
        maximumArchiveEntryCount: Int = 10,
        maximumArchivePathDepth: Int = 4,
        maximumSyncResponseBytes: Int = 1_024
    ) -> LocalFirstResourceLimits {
        LocalFirstResourceLimits(
            maximumCompressedBudgetBytes: maximumCompressedBudgetBytes,
            maximumExpandedBudgetBytes: maximumExpandedBudgetBytes,
            maximumArchiveEntryBytes: maximumArchiveEntryBytes,
            maximumArchiveEntryCount: maximumArchiveEntryCount,
            maximumArchivePathDepth: maximumArchivePathDepth,
            minimumFreeDiskReserveBytes: 0,
            maximumSyncResponseBytes: maximumSyncResponseBytes
        )
    }

    func makeArchive(at url: URL, entries: [(String, Data)]) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
    }

    func markBudgetArtifactAsUnhardened(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try mutableURL.setResourceValues(values)
        #if os(iOS) && !targetEnvironment(simulator)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: url.path
        )
        #endif
    }

    func expectBudgetArtifactIsHardened(_ url: URL) throws {
        #if os(iOS) && !targetEnvironment(simulator)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(
            attributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )
        #else
        // Simulator file metadata is not evidence of effective iOS protection or backup policy.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #endif
    }

    func makeArchiveData(databaseURL: URL) throws -> Data {
        let archiveURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistReimport-\(UUID().uuidString).zip")
        try makeArchive(
            at: archiveURL,
            entries: [("db.sqlite", try Data(contentsOf: databaseURL))]
        )
        return try Data(contentsOf: archiveURL)
    }

    func testRemoteFile() -> ActualSyncRemoteFile {
        ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Budget"
        )
    }

    func testBudgetMetadata() -> LocalFirstBudgetMetadata {
        LocalFirstBudgetMetadata(
            localBudgetID: "file-1",
            cloudFileID: "file-1",
            groupID: "group-1",
            budgetName: "Budget",
            encryptionKeyID: nil,
            nodeID: "node"
        )
    }

    func makeTransaction(
        id: String,
        account: String = "checking",
        category: String?,
        payee: String? = nil,
        date: String = "2026-07-03",
        isParent: Bool = false,
        subtransactions: [ActualTransaction] = []
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: account,
            date: date,
            amount: -1000,
            payee: payee,
            payeeName: nil,
            importedPayee: nil,
            category: category,
            notes: nil,
            cleared: nil,
            subtransactions: subtransactions,
            isParent: isParent
        )
    }

    func makeStore() -> LocalFirstActualStore {
        LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
        )
    }

    func makeOpenedWritableStore(
        additionalFixtureSQL: String = ""
    ) async throws -> LocalFirstActualStore {
        try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: additionalFixtureSQL
        ).store
    }

    func makeAppState(for bundle: OpenedWritableStoreBundle) throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.save(
            AppSettings(
                localFirstServerURLString: "https://sync.example",
                selectedBudgetID: "group-1",
                selectedBudgetName: "Writable Budget",
                selectedLocalFirstFileID: "file-1",
                selectedLocalFirstGroupID: "group-1"
            )
        )
        return AppState(
            settingsStore: settingsStore,
            keychain: bundle.keychain,
            localFirstStore: bundle.store
        )
    }

    func makeOpenedWritableStoreBundle(
        syncTransportFactory: @escaping @Sendable (URL) -> any ActualSyncTransport = { ActualServerSyncClient(baseURL: $0) },
        connectionTransportFactory: @escaping @Sendable (URL) -> any ActualServerConnectionTransport = {
            ActualServerSyncClient(baseURL: $0)
        },
        pendingLocalMessageFlushRetryDelays: [Duration] = [.zero, .seconds(2), .seconds(8), .seconds(30)],
        additionalFixtureSQL: String = "",
        reimportFailureCheckpoint: BudgetReimportCheckpoint? = nil
    ) async throws -> OpenedWritableStoreBundle {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER;
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
            INSERT INTO payees VALUES ('coffee', 'Coffee Shop', NULL, 0);
            INSERT INTO payee_mapping VALUES ('coffee', 'coffee');
            INSERT INTO categories VALUES ('utilities', 'Utilities', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('utilities', 'utilities');
            INSERT INTO zero_budgets VALUES (202607, 'utilities', 0, 0);
            INSERT INTO accounts VALUES ('credit', 'Credit Card', 0, 0, 0, 2);
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 3);
            INSERT INTO accounts VALUES ('tracking', 'Tracking', 1, 0, 0, 4);
            INSERT INTO payees VALUES ('xfer-checking', '', 'checking', 0);
            INSERT INTO payees VALUES ('xfer-credit', '', 'credit', 0);
            INSERT INTO payees VALUES ('xfer-savings', '', 'savings', 0);
            INSERT INTO payees VALUES ('xfer-tracking', '', 'tracking', 0);
            INSERT INTO payee_mapping VALUES ('xfer-checking', 'xfer-checking');
            INSERT INTO payee_mapping VALUES ('xfer-credit', 'xfer-credit');
            INSERT INTO payee_mapping VALUES ('xfer-savings', 'xfer-savings');
            INSERT INTO payee_mapping VALUES ('xfer-tracking', 'xfer-tracking');
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories SET goal_def = '[{"type":"simple","monthly":700,"limit":null,"priority":null,"directive":"template"}]' WHERE id = 'groceries';
            UPDATE categories SET goal_def = '[{"type":"simple","monthly":300,"limit":null,"priority":null,"directive":"template"}]' WHERE id = 'utilities';
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('dining', 'Dining', 'group', 0, 0, 0, 3, '[{"type":"average","numMonths":3,"priority":null,"directive":"template"}]');
            INSERT INTO category_mapping VALUES ('dining', 'dining');
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('subscriptions', 'Subscriptions', 'group', 0, 0, 0, 4, '[{"type":"periodic","amount":45,"period":{"amount":1,"period":"month"},"starting":"2026-07-01","limit":null,"priority":null,"directive":"template"}]');
            INSERT INTO category_mapping VALUES ('subscriptions', 'subscriptions');
            INSERT INTO zero_budgets VALUES (202607, 'subscriptions', 0, 0);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('copycat', 'Copycat', 'group', 0, 0, 0, 5, '[{"type":"copy","lookBack":1,"limit":null,"priority":null,"directive":"template"}]');
            INSERT INTO category_mapping VALUES ('copycat', 'copycat');
            INSERT INTO zero_budgets VALUES (202607, 'copycat', 0, 0);
            \(additionalFixtureSQL)
            """)
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistWritableStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(
            applicationSupportURL: rootURL,
            reimportFailureInjector: { checkpoint in
                if checkpoint == reimportFailureCheckpoint {
                    throw LocalFirstTestSyncError.failed
                }
            }
        )
        let fileID = "file-1"
        let budgetDirectory = try fileManager.budgetDirectory(fileID: fileID)
        try FileManager.default.createDirectory(at: budgetDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL, to: fileManager.databaseURL(fileID: fileID))
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: "group-1",
            budgetName: "Writable Budget",
            encryptionKeyID: nil,
            nodeID: "node1"
        )
        try JSONEncoder.actual.encode(metadata).write(to: fileManager.metadataURL(fileID: fileID))
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            syncTransportFactory: syncTransportFactory,
            connectionTransportFactory: connectionTransportFactory,
            pendingLocalMessageFlushRetryDelays: pendingLocalMessageFlushRetryDelays
        )
        let budget = ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: "group-1",
            name: "Writable Budget",
            state: nil
        )
        _ = try await store.openCachedBudget(budget)
        return OpenedWritableStoreBundle(store: store, fileManager: fileManager, keychain: keychain, budget: budget)
    }

    func makeDate(year: Int, month: Int, day: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return try #require(components.date)
    }

    func remoteMessage(
        index: Int,
        row: String,
        column: String,
        value: LocalFirstSyncValue
    ) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: String(
                format: "2026-07-25T12:00:00.000Z-%04x-remote",
                index
            ),
            dataset: "transactions",
            row: row,
            column: column,
            serializedValue: value.serialized
        )
    }

    func makeSQLiteFixture(extraSQL: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
                CREATE TABLE zero_budgets (
                    month INTEGER,
                    category TEXT,
                    amount INTEGER,
                    carryover INTEGER
                );
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    date INTEGER,
                    amount INTEGER,
                    category TEXT,
                    tombstone INTEGER,
                    parent_id TEXT,
                    is_parent INTEGER
                );
                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );
                CREATE TABLE messages_crdt (
                    timestamp TEXT,
                    dataset TEXT,
                    row TEXT,
                    column TEXT,
                    value TEXT
                );
                INSERT INTO accounts VALUES ('checking', 'Checking', 0, 0, 0, 1);
                INSERT INTO category_groups VALUES ('group', 'Everyday', 0, 0, 0, 1);
                INSERT INTO categories VALUES ('groceries', 'Groceries', 'group', 0, 0, 0, 1);
                INSERT INTO category_mapping VALUES ('groceries', 'groceries');
                INSERT INTO zero_budgets VALUES (202607, 'groceries', 50000, 1);
                INSERT INTO transactions VALUES ('txn', 'checking', 20260703, -12345, 'groceries', 0, NULL, 0);
                """)
            if !extraSQL.isEmpty {
                try db.execute(sql: extraSQL)
            }
        }
        return url
    }
}
