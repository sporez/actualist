import Foundation
import GRDB
import Testing
@testable import Actualist

/// A portable import registers a new, empty server group, so the carried CRDT
/// history must be cleared like upstream's `resetSync`
/// (`loot-core/src/server/sync/reset.ts`).
@Suite @MainActor
struct PortableBudgetImportSyncResetTests {
    private let support = LocalFirstActualStoreTests()
    private static let carriedTimestamp = "2026-07-04T12:05:00.000Z-0000-nodeb"

    private actor AcceptingRegistrationTransport: ActualFileRegistrationTransport {
        func uploadUserFile(
            fileID: String, name: String, groupID: String?, encryptMeta: ActualEncryptedMetadata?,
            bytes: Data, token: String
        ) async throws -> ActualUploadUserFileResponse {
            ActualUploadUserFileResponse(groupID: "group-imported")
        }

        func createUserKey(
            fileID: String, keyID: String, keySalt: String, testContent: String, token: String
        ) async throws {}

        func deleteUserFile(fileID: String, token: String) async throws {}
    }

    /// Exports a source budget that carries CRDT history and tombstoned rows,
    /// then imports it into a second store whose sync transport is `transport`.
    private func importCarryingHistory(
        transport: MerkleAwareSyncTransport
    ) async throws -> (store: LocalFirstActualStore, fileManager: BudgetFileManager, creation: NewBudgetCreation) {
        let source = try await support.makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            INSERT INTO transactions (id, acct, date, amount, tombstone)
                VALUES ('dead-txn', 'checking', 20260701, -100, 1);
            INSERT INTO accounts VALUES ('dead-acct', 'Dead', 0, 0, 1, 9);
            INSERT INTO payees VALUES ('dead-payee', 'Dead', NULL, 1);
            """)
        let sourceDatabase = try source.store.requireDatabase(for: "group-1")
        _ = try await sourceDatabase.applyRemoteSyncMessages([
            ActualSyncDecodedMessage(
                timestamp: Self.carriedTimestamp, dataset: "payees", row: "coffee",
                column: "name", serializedValue: "S:Carried"
            )
        ])
        let archiveURL = FileManager.default.temporaryDirectory
            .appending(path: "PortableResetSource-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        _ = try await PortableBudgetArchive().export(
            database: sourceDatabase, budgetName: "Carried", sourceIdentity: "group-1", to: archiveURL
        )

        let destination = try await support.makeOpenedWritableStoreBundle { _ in transport }
        try destination.keychain.saveActualSyncToken("token")
        let creation = try await destination.store.importPortableBudget(
            archiveAt: archiveURL,
            serverURLString: "https://sync.example",
            token: "token",
            registrationTransport: AcceptingRegistrationTransport(),
            identityGenerator: { "imported-file" }
        )
        return (destination.store, destination.fileManager, creation)
    }

    @Test func installedPortableFileCarriesNoCRDTHistoryOrTombstonedRows() async throws {
        let imported = try await importCarryingHistory(transport: MerkleAwareSyncTransport())

        let databaseURL = try imported.fileManager.databaseURL(fileID: imported.creation.fileID)
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") == 0)
            for table in ["transactions", "accounts", "payees"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE tombstone = 1") == 0)
            }
            let clockRows = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'messages_clock')"
            ) == true ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_clock") : 0
            #expect(clockRows == 0)
            // Live rows survive the reset.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payees WHERE id = 'coffee'") == 1)
        }
    }

    @Test(.timeLimit(.minutes(1))) func importedBudgetSyncsAgainstTheEmptyRegisteredGroup() async throws {
        let transport = MerkleAwareSyncTransport()
        let imported = try await importCarryingHistory(transport: transport)
        let groupID = try #require(imported.creation.groupID)
        let metadata = try #require(try imported.fileManager.loadMetadata(fileID: imported.creation.fileID))
        try await imported.store.openImportedBudget(fileID: imported.creation.fileID, metadata: metadata)

        _ = try await imported.store.pullAndReload(
            budgetID: groupID, serverURLString: "https://sync.example"
        )

        let database = try imported.store.requireDatabase(for: groupID)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try await database.merkleDivergence(from: await transport.merkle()) == nil)
    }
}
