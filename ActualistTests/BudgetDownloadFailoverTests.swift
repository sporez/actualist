import Foundation
import Testing
@testable import Actualist

@MainActor
@Suite("Budget Download Failover")
struct BudgetDownloadFailoverTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test("openBudget first download fails over to fallback when primary is unreachable")
    func openBudgetFirstDownloadFailsOverWhenPrimaryUnreachable() async throws {
        let archiveData = try fixtures.makeArchiveData(databaseURL: fixtures.makeSQLiteFixture())
        let primary = ConfigurableConnectionTransport(error: .transport(.cannotConnectToHost))
        let fallback = ConfigurableConnectionTransport(
            files: [fixtures.testRemoteFile()],
            downloadData: archiveData
        )
        let store = try makeFirstDownloadStore(primary: primary, fallback: fallback)

        try await store.openBudget(testDownloadBudget(), serverURLString: primaryServerURLString)

        #expect(store.isOpen(budgetID: "group-1"))
        #expect(await fallback.recordedMethods() == [.userFileInfo, .downloadUserFile])
    }

    @Test("openBudget first download does not fail over on a server-rejected download")
    func openBudgetFirstDownloadDoesNotFailOverOnServerRejectedDownload() async throws {
        let primary = ConfigurableConnectionTransport(
            methodErrors: [
                .downloadUserFile: .serverRejected(status: 500, reason: "internal", details: nil)
            ],
            files: [fixtures.testRemoteFile()]
        )
        let fallback = ConfigurableConnectionTransport()
        let store = try makeFirstDownloadStore(primary: primary, fallback: fallback)

        await #expect(throws: ActualAPIError.self) {
            try await store.openBudget(testDownloadBudget(), serverURLString: primaryServerURLString)
        }
        #expect(await fallback.recordedMethods().isEmpty)
        #expect(!store.isOpen(budgetID: "group-1"))
    }

    @Test("openBudget first download retries over a partial primary download")
    func openBudgetFirstDownloadRetriesOverPartialPrimaryDownload() async throws {
        // Stub-level retry: the primary writes a prefix then throws a failover-eligible
        // error; the fallback overwrites the staging file with a complete archive.
        // This does not exercise ActualServerSyncClient.performDownload truncate /
        // delete-on-error; those are covered by existing download-client tests.
        let primaryArchive = try fixtures.makeArchiveData(databaseURL: fixtures.makeSQLiteFixture())
        let replacementArchive = try fixtures.makeArchiveData(
            databaseURL: fixtures.makeSQLiteFixture(
                extraSQL: "INSERT INTO accounts VALUES ('replacement', 'Replacement', 0, 0, 0, 2)"
            )
        )
        let primary = ConfigurableConnectionTransport(
            methodErrors: [.downloadUserFile: .transport(.cannotConnectToHost)],
            files: [fixtures.testRemoteFile()],
            downloadData: primaryArchive,
            writePartialPrefixBeforeThrowingDownloadError: true
        )
        let fallback = ConfigurableConnectionTransport(
            files: [fixtures.testRemoteFile()],
            downloadData: replacementArchive
        )
        let store = try makeFirstDownloadStore(primary: primary, fallback: fallback)

        try await store.openBudget(testDownloadBudget(), serverURLString: primaryServerURLString)

        #expect(store.isOpen(budgetID: "group-1"))
        let accounts = store.accountDisplays(budgetID: "group-1").map(\.account.id)
        #expect(accounts.contains("replacement"))
        #expect(await fallback.recordedMethods() == [.userFileInfo, .downloadUserFile])
    }

    @Test("openBudget first download tolerates userFileInfo 404 and continues on primary")
    func openBudgetFirstDownloadToleratesUserFileInfo404() async throws {
        let archiveData = try fixtures.makeArchiveData(databaseURL: fixtures.makeSQLiteFixture())
        let primary = ConfigurableConnectionTransport(
            methodErrors: [.userFileInfo: .httpStatus(404)],
            files: [fixtures.testRemoteFile()],
            downloadData: archiveData
        )
        let fallback = ConfigurableConnectionTransport()
        let store = try makeFirstDownloadStore(primary: primary, fallback: fallback)
        store.remoteFilesByFileID["file-1"] = fixtures.testRemoteFile()

        try await store.openBudget(testDownloadBudget(), serverURLString: primaryServerURLString)

        #expect(store.isOpen(budgetID: "group-1"))
        #expect(await primary.recordedMethods() == [.userFileInfo, .downloadUserFile])
        #expect(await fallback.recordedMethods().isEmpty)
    }

    @Test("openBudget encrypted-already-imported path fails over on userKey")
    func openBudgetEncryptedAlreadyImportedFailsOverOnUserKey() async throws {
        let password = "budget password"
        // Encryption keys are stored as service + fileID + keyID. The KeychainStore
        // account UUID only isolates the sync token, so a shared "key-1" is reused
        // by any other test writing to `com.sporez.actualist.tests`.
        let keyID = "failover-userkey-\(UUID().uuidString)"
        let keyResponse = try makeUserKeyResponse(password: password, keyID: keyID, salt: "server-salt")
        let primary = ConfigurableConnectionTransport(error: .transport(.cannotConnectToHost))
        let fallback = ConfigurableConnectionTransport(userKeyResponse: keyResponse)
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { url in
                url.absoluteString == primaryServerURLString ? primary : fallback
            }
        )
        defer {
            try? bundle.keychain.removeLocalFirstEncryptionKey(fileID: "file-1", keyID: keyID)
        }
        bundle.store.closeOpenBudget()
        let encryptedMetadata = LocalFirstBudgetMetadata(
            localBudgetID: "file-1",
            cloudFileID: "file-1",
            groupID: "group-1",
            budgetName: "Writable Budget",
            encryptionKeyID: keyID,
            nodeID: "node1"
        )
        try JSONEncoder.actual.encode(encryptedMetadata)
            .write(to: bundle.fileManager.metadataURL(fileID: "file-1"))
        try bundle.keychain.saveActualSyncToken("token")
        bundle.store.fallbackServerURLString = fallbackServerURLString

        try await bundle.store.openBudget(
            bundle.budget,
            serverURLString: primaryServerURLString,
            encryptionPassword: password
        )

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(await fallback.recordedMethods() == [.userKey])
    }

    @Test("reimportBudget fails over to fallback when primary is unreachable")
    func reimportBudgetFailsOverWhenPrimaryUnreachable() async throws {
        let replacementArchive = try fixtures.makeArchiveData(
            databaseURL: fixtures.makeSQLiteFixture(
                extraSQL: "INSERT INTO accounts VALUES ('replacement', 'Replacement', 0, 0, 0, 2)"
            )
        )
        let primary = ConfigurableConnectionTransport(error: .transport(.cannotConnectToHost))
        let fallback = ConfigurableConnectionTransport(
            files: [fixtures.testRemoteFile()],
            downloadData: replacementArchive
        )
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { url in
                url.absoluteString == primaryServerURLString ? primary : fallback
            }
        )
        try bundle.keychain.saveActualSyncToken("token")
        bundle.store.fallbackServerURLString = fallbackServerURLString

        try await bundle.store.reimportBudget(
            bundle.budget,
            serverURLString: primaryServerURLString
        )

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let accounts = bundle.store.accountDisplays(budgetID: "group-1").map(\.account.id)
        #expect(accounts.contains("replacement"))
        #expect(try bundle.fileManager.reimportBackupExists(fileID: "file-1"))
        #expect(await fallback.recordedMethods() == [.userFileInfo, .downloadUserFile])
    }

    @Test("reimportBudget does not fail over on a server-rejected download")
    func reimportBudgetDoesNotFailOverOnServerRejectedDownload() async throws {
        let primary = ConfigurableConnectionTransport(
            methodErrors: [
                .downloadUserFile: .serverRejected(status: 500, reason: "internal", details: nil)
            ],
            files: [fixtures.testRemoteFile()]
        )
        let fallback = ConfigurableConnectionTransport()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { url in
                url.absoluteString == primaryServerURLString ? primary : fallback
            }
        )
        try bundle.keychain.saveActualSyncToken("token")
        bundle.store.fallbackServerURLString = fallbackServerURLString
        let original = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )

        await #expect(throws: ActualAPIError.self) {
            try await bundle.store.reimportBudget(
                bundle.budget,
                serverURLString: primaryServerURLString
            )
        }

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let restored = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        #expect(restored.month == original.month)
        #expect(await fallback.recordedMethods().isEmpty)
        let leftoverNames = try FileManager.default.contentsOfDirectory(
            atPath: bundle.fileManager.applicationSupportURL.appending(path: "Budgets").path
        )
        #expect(!leftoverNames.contains { $0.contains(".reimport-") })
    }
}

private let primaryServerURLString = "https://primary.example.com"
private let fallbackServerURLString = "https://fallback.example.com"

private func testDownloadBudget() -> ActualBudget {
    ActualBudget(
        budgetID: "file-1",
        cloudFileId: "file-1",
        groupId: "group-1",
        name: "Budget",
        state: nil
    )
}

@MainActor
private func makeFirstDownloadStore(
    primary: ConfigurableConnectionTransport,
    fallback: ConfigurableConnectionTransport
) throws -> LocalFirstActualStore {
    let fileManager = BudgetFileManager(
        applicationSupportURL: FileManager.default.temporaryDirectory
            .appending(
                path: "ActualistDownloadFailover-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    )
    let keychain = KeychainStore(
        service: "com.sporez.actualist.tests",
        account: UUID().uuidString
    )
    try keychain.saveActualSyncToken("token")
    let store = LocalFirstActualStore(
        keychain: keychain,
        fileManager: fileManager,
        syncTransportFactory: { _ in RecordingSyncTransport() },
        connectionTransportFactory: { url in
            url.absoluteString == primaryServerURLString ? primary : fallback
        }
    )
    store.fallbackServerURLString = fallbackServerURLString
    return store
}

private func makeUserKeyResponse(
    password: String,
    keyID: String,
    salt: String
) throws -> ActualUserKeyResponse {
    let keyData = try ActualBudgetCrypto.deriveKey(password: password, salt: salt)
    let context = ActualBudgetEncryptionContext(keyID: keyID, keyData: keyData)
    let encrypted = try ActualBudgetCrypto.encrypt(Data("test-value".utf8), context: context)
    let testPayload = ActualUserKeyResponse.TestPayload(
        value: encrypted.data.base64EncodedString(),
        meta: ActualEncryptedMetadata(
            keyID: keyID,
            algorithm: ActualBudgetCrypto.algorithm,
            iv: encrypted.iv.base64EncodedString(),
            authTag: encrypted.authTag.base64EncodedString()
        )
    )
    return ActualUserKeyResponse(
        id: keyID,
        salt: salt,
        test: String(data: try JSONEncoder.actual.encode(testPayload), encoding: .utf8)
    )
}
