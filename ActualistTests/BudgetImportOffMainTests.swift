import Foundation
import Testing
@testable import Actualist

/// Concurrency remediation 4.3: ZIP extraction, decryption, sanitizing and
/// portable validation must not run on the main thread on the open, reimport
/// and portable-import paths. DEBUG builds log main-thread calls into
/// `MainThreadCallLog`; each test looks up the key only its own scenario
/// passes through each stage (a path under its store root, a fresh IV, or its
/// own archive path).
@MainActor
@Suite("Budget import off main")
struct BudgetImportOffMainTests {
    private let support = LocalFirstActualStoreTests()

    private func makeStore(
        root: URL,
        transport: ConfigurableConnectionTransport
    ) throws -> LocalFirstActualStore {
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: FakeKeychainBackend()
        )
        try keychain.saveActualSyncToken("token")
        return LocalFirstActualStore(
            keychain: keychain,
            fileManager: BudgetFileManager(applicationSupportURL: root),
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { _ in transport }
        )
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ImportOffMain-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func downloadBudget() -> ActualBudget {
        ActualBudget(budgetID: "file-1", cloudFileId: "file-1", groupId: "group-1", name: "Budget", state: nil)
    }

    @Test func plainDownloadOpenExtractsAndSanitizesOffTheMainThread() async throws {
        let root = makeRoot()
        let archive = try support.makeArchiveData(databaseURL: support.makeSQLiteFixture())
        let transport = ConfigurableConnectionTransport(files: [support.testRemoteFile()], downloadData: archive)
        let store = try makeStore(root: root, transport: transport)

        try await store.openBudget(downloadBudget(), serverURLString: "https://sync.example")

        #expect(store.isOpen(budgetID: "group-1"))
        let name = root.lastPathComponent
        #expect(MainThreadCallLog.mainThreadCalls(stage: "importBudgetZip", keyContaining: name).isEmpty)
        #expect(MainThreadCallLog.mainThreadCalls(stage: "sanitize", keyContaining: name).isEmpty)
    }

    @Test func encryptedDownloadOpenDecryptsOffTheMainThread() async throws {
        let password = "budget password"
        let salt = "server salt"
        let keyID = "off-main-key-\(UUID().uuidString)"
        let keyData = try ActualBudgetCrypto.deriveKey(password: password, salt: salt)
        let context = ActualBudgetEncryptionContext(keyID: keyID, keyData: keyData)
        let archive = try support.makeArchiveData(databaseURL: support.makeSQLiteFixture())
        let encrypted = try ActualBudgetCrypto.encrypt(archive, context: context)
        let remote = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Budget",
            encryptKeyID: keyID,
            encryptMeta: ActualEncryptedMetadata(
                keyID: keyID,
                algorithm: ActualBudgetCrypto.algorithm,
                iv: encrypted.iv.base64EncodedString(),
                authTag: encrypted.authTag.base64EncodedString()
            ),
            requiresEncryptionPassword: true
        )
        let transport = ConfigurableConnectionTransport(
            files: [remote],
            downloadData: encrypted.data,
            userKeyResponse: try makeUserKeyResponse(password: password, keyID: keyID, salt: salt)
        )
        let store = try makeStore(root: makeRoot(), transport: transport)

        try await store.openBudget(
            downloadBudget(),
            serverURLString: "https://sync.example",
            encryptionPassword: password
        )

        #expect(store.isOpen(budgetID: "group-1"))
        let iv = encrypted.iv.base64EncodedString()
        #expect(MainThreadCallLog.mainThreadCalls(stage: "decrypt", keyContaining: iv).isEmpty)
    }

    @Test func reimportExtractsAndSanitizesOffTheMainThread() async throws {
        let replacement = try support.makeSQLiteFixture(
            extraSQL: "INSERT INTO accounts VALUES ('replacement', 'Replacement', 0, 0, 0, 2)"
        )
        let transport = StubConnectionTransport(
            files: [support.testRemoteFile()],
            token: "reimport-token",
            downloadData: try support.makeArchiveData(databaseURL: replacement)
        )
        let bundle = try await support.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("reimport-token")

        try await bundle.store.reimportBudget(bundle.budget, serverURLString: "https://sync.example")

        let name = bundle.fileManager.applicationSupportURL.lastPathComponent
        #expect(MainThreadCallLog.mainThreadCalls(stage: "importBudgetZip", keyContaining: name).isEmpty)
        #expect(MainThreadCallLog.mainThreadCalls(stage: "sanitize", keyContaining: name).isEmpty)
    }

    @Test func portableImportValidatesOffTheMainThread() async throws {
        let sourceRoot = makeRoot()
        let uploader = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-source"))]
        )
        let source = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString,
                backend: FakeKeychainBackend()
            ),
            fileManager: BudgetFileManager(applicationSupportURL: sourceRoot)
        )
        _ = try await source.createNewBudget(
            named: "Portable Source",
            serverURLString: "https://newbudget.example",
            token: "session-token",
            registrationTransport: uploader
        )
        let archiveURL = FileManager.default.temporaryDirectory
            .appending(path: "portable-off-main-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        try #require(await uploader.uploads.first).bytes.write(to: archiveURL)

        let target = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString,
                backend: FakeKeychainBackend()
            ),
            fileManager: BudgetFileManager(applicationSupportURL: makeRoot())
        )
        _ = try await target.importPortableBudget(
            archiveAt: archiveURL,
            serverURLString: "https://newbudget.example",
            token: "session-token",
            registrationTransport: NewBudgetFakeRegistrationTransport(
                uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-target"))]
            )
        )

        #expect(MainThreadCallLog.mainThreadCalls(stage: "portableValidate", keyContaining: archiveURL.lastPathComponent).isEmpty)
    }
}
