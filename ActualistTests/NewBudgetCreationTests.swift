import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

/// New Budget creation coverage: the starter seed projection, the portable
/// archive the create flow uploads, and the no-selectable-budget-on-failure
/// invariant. Everything runs against a synthetic seed (runtime-generated
/// identities) and a fake registration transport; no server is contacted.
/// Fakes and stores are fresh per test.
struct NewBudgetCreationTests {
    // MARK: - Fixtures

    @MainActor
    private func makeStore(
        fileSystem: FileManager = .default
    ) -> (store: LocalFirstActualStore, fileManager: BudgetFileManager) {
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: FakeKeychainBackend()
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NewBudget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL, fileManager: fileSystem)
        let store = LocalFirstActualStore(keychain: keychain, fileManager: fileManager)
        return (store, fileManager)
    }

    private func makeIdentitySequence(prefix: String) -> @Sendable () -> String {
        let sequence = IdentitySequence(prefix: prefix)
        return { sequence.generate() }
    }

    // MARK: - Confirmed creation

    @MainActor
    @Test func createRegistersKnownFileIDAndWritesConfirmedMetadata() async throws {
        let (store, fileManager) = makeStore()
        let seedIdentity = makeIdentitySequence(prefix: "seed")
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))]
        )

        let creation = try await store.createNewBudget(
            named: "  Fresh Budget  ",
            serverURLString: "https://newbudget.example",
            token: "session-token",
            registrationTransport: transport,
            identityGenerator: seedIdentity
        )

        #expect(creation.groupID == "group-new")
        #expect(creation.budgetName == "Fresh Budget")
        #expect(creation.encryptionKeyID == nil)
        let uploads = await transport.uploads
        #expect(uploads.count == 1)
        #expect(uploads[0].fileID == creation.fileID)
        #expect(uploads[0].name == "Fresh Budget")
        #expect(uploads[0].groupID == nil)
        #expect(uploads[0].token == "session-token")
        #expect(await transport.createKeyCalls.isEmpty)

        // The completed identity is locally selectable and carries the
        // receipt's group identity — nothing more.
        let metadata = try #require(try fileManager.loadMetadata(fileID: creation.fileID))
        #expect(metadata.cloudFileID == creation.fileID)
        #expect(metadata.groupID == "group-new")
        #expect(metadata.budgetName == "Fresh Budget")
        #expect(metadata.encryptionKeyID == nil)
        #expect(try fileManager.importedBudgetFileIDs() == [creation.fileID])
    }

    @MainActor
    @Test func encryptedCreateRegistersKeyAndWritesKeyIDToMetadata() async throws {
        let (store, fileManager) = makeStore()
        let seedIdentity = makeIdentitySequence(prefix: "seed")
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))]
        )

        let creation = try await store.createNewBudget(
            named: "Fresh Budget",
            serverURLString: "https://newbudget.example",
            encryptionPassword: "secret-passphrase",
            token: "session-token",
            registrationTransport: transport,
            identityGenerator: seedIdentity
        )

        let keyID = try #require(creation.encryptionKeyID)
        let createKey = try #require(await transport.createKeyCalls.first)
        #expect(createKey.fileID == creation.fileID)
        #expect(createKey.keyID == keyID)
        let metadata = try #require(try fileManager.loadMetadata(fileID: creation.fileID))
        #expect(metadata.encryptionKeyID == keyID)
        let savedKey = try store.keychain.readLocalFirstEncryptionKey(
            fileID: creation.fileID,
            keyID: keyID
        )
        #expect(savedKey != nil)
    }

    // MARK: - Starter seed projection

    @MainActor
    @Test func createProjectsStarterSeedStructure() async throws {
        let (store, fileManager) = makeStore()
        let seedIdentity = makeIdentitySequence(prefix: "seed")
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))]
        )

        let creation = try await store.createNewBudget(
            named: "Fresh Budget",
            serverURLString: "https://newbudget.example",
            token: "session-token",
            registrationTransport: transport,
            identityGenerator: seedIdentity
        )

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(
            path: fileManager.databaseURL(fileID: creation.fileID).path,
            configuration: configuration
        )
        try await queue.read { db in
            let groupNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM category_groups ORDER BY sort_order"
            )
            #expect(groupNames == ["Usual Expenses", "Investments and Savings", "Income"])
            let incomeGroupNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM category_groups WHERE is_income = 1"
            )
            #expect(incomeGroupNames == ["Income"])

            let categoryNames = try String.fetchAll(
                db,
                sql: """
                    SELECT c.name FROM categories c
                    JOIN category_groups g ON g.id = c.cat_group
                    ORDER BY g.sort_order, c.sort_order
                    """
            )
            #expect(categoryNames == [
                "Food", "General", "Bills", "Bills (Flexible)",
                "Savings", "Income", "Starting Balances"
            ])
            let incomeCategoryNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM categories WHERE is_income = 1"
            )
            #expect(Set(incomeCategoryNames) == ["Income", "Starting Balances"])

            // Every category attaches to a starter group; row identities are
            // freshly generated and display order values are unique.
            let orphanCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM categories c
                    WHERE c.cat_group IS NULL
                       OR NOT EXISTS(SELECT 1 FROM category_groups g WHERE g.id = c.cat_group)
                    """
            ) ?? -1
            #expect(orphanCount == 0)
            let groupIDs = try String.fetchAll(db, sql: "SELECT id FROM category_groups")
            let categoryIDs = try String.fetchAll(db, sql: "SELECT id FROM categories")
            #expect(Set(groupIDs + categoryIDs).count == groupIDs.count + categoryIDs.count)
            let groupOrders = try Double.fetchAll(db, sql: "SELECT sort_order FROM category_groups")
            let categoryOrders = try Double.fetchAll(db, sql: "SELECT sort_order FROM categories")
            #expect(Set(groupOrders).count == groupOrders.count)
            #expect(Set(categoryOrders).count == categoryOrders.count)

            // Zero accounts, zero transactions, zero CRDT history.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") == 0)
        }
    }

    @MainActor
    @Test func uploadedArchiveIsAValidPortableSnapshot() async throws {
        let (store, _) = makeStore()
        let seedIdentity = makeIdentitySequence(prefix: "seed")
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))]
        )

        let creation = try await store.createNewBudget(
            named: "Fresh Budget",
            serverURLString: "https://newbudget.example",
            token: "session-token",
            registrationTransport: transport,
            identityGenerator: seedIdentity
        )

        let uploads = await transport.uploads
        let archiveBytes = try #require(uploads.first?.bytes)
        #expect(!archiveBytes.isEmpty)

        let work = FileManager.default.temporaryDirectory
            .appending(path: "NewBudget-validate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archiveURL = work.appending(path: "uploaded.zip")
        try archiveBytes.write(to: archiveURL)

        let validated = try PortableBudgetArchive().validate(
            archiveAt: archiveURL,
            stagingDirectory: work
        )
        #expect(validated.metadata.budgetName == "Fresh Budget")
        #expect(validated.metadata.resetClock == true)
        // The archive identity is minted by the portable export, never the
        // registration file ID.
        #expect(validated.metadata.id != creation.fileID)

        let uploaded = try DatabaseQueue(path: validated.databaseURL.path)
        let localObjects = try await uploaded.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master")
                .filter { $0.lowercased().hasPrefix(ActualSyncDatasetPolicy.localTablePrefix) }
        }
        #expect(localObjects == [])

        let database = try BudgetDatabase(databaseURL: validated.databaseURL)
        try await database.validateImportedBudget()
    }

    // MARK: - Failure cleanup

    @MainActor
    @Test func unconfirmableUploadDeletesLocalDirectory() async throws {
        let (store, fileManager) = makeStore()
        let seedIdentity = makeIdentitySequence(prefix: "seed")
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.failure(ActualAPIError.transport(.timedOut))]
        )
        let recovery = NewBudgetRegistrationRecoveryStub(listResults: [.success([])])

        await #expect(throws: ActualFileRegistrationError.uploadUnconfirmed) {
            try await store.createNewBudget(
                named: "Fresh Budget",
                serverURLString: "https://newbudget.example",
                token: "session-token",
                registrationTransport: transport,
                listUserFiles: recovery.listUserFiles,
                userInfo: recovery.userInfo,
                identityGenerator: seedIdentity
            )
        }

        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
        // Retries stay under the one known ID — no second identity minted.
        let uploads = await transport.uploads
        #expect(uploads.count == 2)
        #expect(Set(uploads.map(\.fileID)).count == 1)
    }

    /// The failed-creation cleanup used `try?`, so a failed delete left the
    /// half-created budget selectable.
    @MainActor
    @Test func failedCleanupLeavesNoSelectableBudget() async throws {
        let fileSystem = FailingFileManager()
        let (store, fileManager) = makeStore(fileSystem: fileSystem)
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.failure(ActualAPIError.transport(.timedOut))]
        )
        let recovery = NewBudgetRegistrationRecoveryStub(listResults: [.success([])])
        // Positive control: metadata is written before registration, so the
        // budget is selectable when the cleanup's first delete is attempted.
        let metadataSeenAtFirstDelete = Mutex<Bool?>(nil)
        fileSystem.rules.withLock {
            $0.failRemove = { url in
                metadataSeenAtFirstDelete.withLock {
                    $0 = $0 ?? FileManager.default.fileExists(
                        atPath: url.appending(path: "metadata.json").path
                    )
                }
                return true
            }
        }

        await #expect(throws: ActualFileRegistrationError.uploadUnconfirmed) {
            try await store.createNewBudget(
                named: "Fresh Budget",
                serverURLString: "https://newbudget.example",
                token: "session-token",
                registrationTransport: transport,
                listUserFiles: recovery.listUserFiles,
                userInfo: recovery.userInfo,
                identityGenerator: makeIdentitySequence(prefix: "seed")
            )
        }

        #expect(metadataSeenAtFirstDelete.withLock { $0 } == true)
        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
    }

    @MainActor
    @Test func unconfirmedKeyRegistrationDeletesLocalDirectory() async throws {
        let (store, fileManager) = makeStore()
        let seedIdentity = makeIdentitySequence(prefix: "seed")
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))],
            createKeyError: ActualFileRegistrationError.keyRegistrationNotConfirmed
        )
        let recovery = NewBudgetRegistrationRecoveryStub()

        await #expect(throws: ActualFileRegistrationError.keyRegistrationNotConfirmed) {
            try await store.createNewBudget(
                named: "Fresh Budget",
                serverURLString: "https://newbudget.example",
                encryptionPassword: "secret-passphrase",
                token: "session-token",
                registrationTransport: transport,
                listUserFiles: recovery.listUserFiles,
                userInfo: recovery.userInfo,
                identityGenerator: seedIdentity
            )
        }

        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
        // The landed-but-undecryptable file is withdrawn, best effort.
        #expect(await transport.events == ["upload", "createKey", "delete"])
        #expect(await transport.deleteCalls == ["seed-1"])
    }

    @MainActor
    @Test func failedDeleteDoesNotReplaceTheKeyRegistrationError() async throws {
        let (store, _) = makeStore()
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))],
            createKeyError: ActualFileRegistrationError.keyRegistrationNotConfirmed,
            deleteError: ActualAPIError.httpStatus(500)
        )

        await #expect(throws: ActualFileRegistrationError.keyRegistrationNotConfirmed) {
            try await store.createNewBudget(
                named: "Fresh Budget",
                serverURLString: "https://newbudget.example",
                encryptionPassword: "secret-passphrase",
                token: "session-token",
                registrationTransport: transport,
                identityGenerator: self.makeIdentitySequence(prefix: "seed")
            )
        }
        #expect(await transport.deleteCalls == ["seed-1"])
    }

    // MARK: - Upload error classification

    @MainActor
    @Test(arguments: [400, 401, 403, 413])
    func terminalUploadStatusIsNeverRetriedOrListed(status: Int) async throws {
        let (store, fileManager) = makeStore()
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.failure(ActualAPIError.httpStatus(status))]
        )
        let recovery = NewBudgetRegistrationRecoveryStub()

        await #expect(throws: ActualAPIError.self) {
            try await store.createNewBudget(
                named: "Fresh Budget",
                serverURLString: "https://newbudget.example",
                token: "session-token",
                registrationTransport: transport,
                listUserFiles: recovery.listUserFiles,
                userInfo: recovery.userInfo,
                identityGenerator: self.makeIdentitySequence(prefix: "seed")
            )
        }
        #expect(await transport.uploads.count == 1)
        #expect(recovery.listCallCount == 0)
        #expect(await transport.deleteCalls.isEmpty)
        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
    }

    @MainActor
    @Test func serverErrorUploadIsReconciledThroughTheList() async throws {
        let (store, _) = makeStore()
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.failure(ActualAPIError.httpStatus(503))]
        )
        let recovery = NewBudgetRegistrationRecoveryStub(listResults: [.success([])])

        await #expect(throws: ActualFileRegistrationError.uploadUnconfirmed) {
            try await store.createNewBudget(
                named: "Fresh Budget",
                serverURLString: "https://newbudget.example",
                token: "session-token",
                registrationTransport: transport,
                listUserFiles: recovery.listUserFiles,
                userInfo: recovery.userInfo,
                identityGenerator: self.makeIdentitySequence(prefix: "seed")
            )
        }
        #expect(await transport.uploads.count == 2)
        #expect(recovery.listCallCount == 2)
    }

    // MARK: - Failure cleanup of the saved key

    @MainActor
    @Test func metadataFailureAfterConfirmationRemovesTheSavedKey() async throws {
        let (store, fileManager) = makeStore()
        // After the upload lands, make the final metadata write fail: an
        // atomic write cannot replace a non-empty directory.
        let metadataURL = try fileManager.metadataURL(fileID: "seed-1")
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))],
            onUpload: { _ in
                try? FileManager.default.removeItem(at: metadataURL)
                try? FileManager.default.createDirectory(
                    at: metadataURL.appending(path: "blocker", directoryHint: .isDirectory),
                    withIntermediateDirectories: true
                )
            }
        )

        await #expect(throws: Error.self) {
            try await store.createNewBudget(
                named: "Fresh Budget",
                serverURLString: "https://newbudget.example",
                encryptionPassword: "secret-passphrase",
                token: "session-token",
                registrationTransport: transport,
                identityGenerator: self.makeIdentitySequence(prefix: "seed")
            )
        }

        let keyID = try #require(await transport.createKeyCalls.first?.keyID)
        #expect(try store.keychain.readLocalFirstEncryptionKey(fileID: "seed-1", keyID: keyID) == nil)
        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
    }

    // MARK: - Name caps

    @MainActor
    @Test func overlongNameIsRefusedBeforeAnyDirectoryOrUpload() async throws {
        let (store, fileManager) = makeStore()
        let transport = NewBudgetFakeRegistrationTransport()

        for name in [
            String(repeating: "a", count: 300),
            // 100 characters, but about 7.5 KB once percent-encoded.
            String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 100)
        ] {
            await #expect(throws: ActualFileRegistrationError.budgetNameTooLong) {
                try await store.createNewBudget(
                    named: name,
                    serverURLString: "https://newbudget.example",
                    token: "session-token",
                    registrationTransport: transport
                )
            }
        }
        #expect(await transport.uploads.isEmpty)
        #expect(try fileManager.importedBudgetFileIDs().isEmpty)

        let boundary = String(repeating: "a", count: 255)
        let creation = try await store.createNewBudget(
            named: boundary,
            serverURLString: "https://newbudget.example",
            token: "session-token",
            registrationTransport: NewBudgetFakeRegistrationTransport(
                uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))]
            )
        )
        #expect(creation.budgetName == boundary)
    }

    @MainActor
    @Test func blankNameIsRefusedBeforeAnyDirectoryOrRegistration() async throws {
        let (store, fileManager) = makeStore()
        let transport = NewBudgetFakeRegistrationTransport()

        await #expect(throws: NewBudgetError.invalidBudgetName) {
            try await store.createNewBudget(
                named: "   ",
                serverURLString: "https://newbudget.example",
                token: "session-token",
                registrationTransport: transport
            )
        }

        #expect(await transport.uploads.isEmpty)
        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
    }

    @MainActor
    @Test func existingDirectoryCollisionIsRefusedWithoutDeletingIt() async throws {
        let (store, fileManager) = makeStore()
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))]
        )
        // The collision generator always mints the same identity, so the
        // create call maps onto the pre-created directory. The constant
        // identity is only ever used for the file ID: the collision guard
        // throws before any starter row is generated.
        let collidingIdentity: @Sendable () -> String = { "collision-id" }
        let directory = try fileManager.budgetDirectory(fileID: collidingIdentity())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinelURL = directory.appending(path: "sentinel.txt")
        try Data("keep".utf8).write(to: sentinelURL)

        await #expect(throws: NewBudgetError.budgetDirectoryAlreadyExists) {
            try await store.createNewBudget(
                named: "Fresh Budget",
                serverURLString: "https://newbudget.example",
                token: "session-token",
                registrationTransport: transport,
                identityGenerator: collidingIdentity
            )
        }

        #expect(await transport.uploads.isEmpty)
        #expect(FileManager.default.fileExists(atPath: sentinelURL.path))
        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
    }
}

// MARK: - Fakes

/// Locked deterministic identity sequence for the file ID and starter rows.
private final class IdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let prefix: String
    private var next = 0

    init(prefix: String) {
        self.prefix = prefix
    }

    func generate() -> String {
        lock.withLock {
            next += 1
            return "\(prefix)-\(next)"
        }
    }
}

/// Queue-driven registration transport with sticky-last semantics: the final
/// result repeats for any further calls, so single-entry queues cover retry
/// paths. Captures full upload bytes so tests can validate the archive.
private actor NewBudgetFakeRegistrationTransport: ActualFileRegistrationTransport {
    struct UploadCall: Equatable {
        let fileID: String
        let name: String
        let groupID: String?
        let byteCount: Int
        let bytes: Data
        let token: String
    }

    struct CreateKeyCall: Equatable {
        let fileID: String
        let keyID: String
        let token: String
    }

    private var uploadResults: [Result<ActualUploadUserFileResponse, Error>]
    private let createKeyError: Error?
    private let deleteError: Error?
    private let onUpload: (@Sendable (String) -> Void)?
    private(set) var uploads: [UploadCall] = []
    private(set) var createKeyCalls: [CreateKeyCall] = []
    private(set) var events: [String] = []
    private(set) var deleteCalls: [String] = []

    init(
        uploadResults: [Result<ActualUploadUserFileResponse, Error>] = [],
        createKeyError: Error? = nil,
        deleteError: Error? = nil,
        onUpload: (@Sendable (String) -> Void)? = nil
    ) {
        self.uploadResults = uploadResults
        self.createKeyError = createKeyError
        self.deleteError = deleteError
        self.onUpload = onUpload
    }

    func uploadUserFile(
        fileID: String,
        name: String,
        groupID: String?,
        encryptMeta: ActualEncryptedMetadata?,
        bytes: Data,
        token: String
    ) async throws -> ActualUploadUserFileResponse {
        uploads.append(UploadCall(
            fileID: fileID, name: name, groupID: groupID,
            byteCount: bytes.count, bytes: bytes, token: token
        ))
        events.append("upload")
        onUpload?(fileID)
        let result: Result<ActualUploadUserFileResponse, Error>
        if uploadResults.isEmpty {
            result = .success(ActualUploadUserFileResponse(groupID: nil))
        } else if uploadResults.count == 1 {
            result = uploadResults[0]
        } else {
            result = uploadResults.removeFirst()
        }
        return try result.get()
    }

    func createUserKey(
        fileID: String,
        keyID: String,
        keySalt: String,
        testContent: String,
        token: String
    ) async throws {
        createKeyCalls.append(CreateKeyCall(fileID: fileID, keyID: keyID, token: token))
        events.append("createKey")
        if let createKeyError { throw createKeyError }
    }

    func deleteUserFile(fileID: String, token: String) async throws {
        deleteCalls.append(fileID)
        events.append("delete")
        if let deleteError { throw deleteError }
    }
}

/// Lock-protected fake for the existing list-user-files / get-user-file-info
/// recovery paths, with the same sticky-last queue semantics.
private final class NewBudgetRegistrationRecoveryStub: @unchecked Sendable {
    private let lock = NSLock()
    private var listResults: [Result<[ActualSyncRemoteFile], Error>]
    private var listCalls = 0

    var listCallCount: Int { lock.withLock { listCalls } }

    init(listResults: [Result<[ActualSyncRemoteFile], Error>] = []) {
        self.listResults = listResults
    }

    var listUserFiles: @Sendable (String) async throws -> [ActualSyncRemoteFile] {
        { [self] _ in
            try lock.withLock {
                listCalls += 1
                let result: Result<[ActualSyncRemoteFile], Error>
                if listResults.isEmpty {
                    result = .success([])
                } else if listResults.count == 1 {
                    result = listResults[0]
                } else {
                    result = listResults.removeFirst()
                }
                return try result.get()
            }
        }
    }

    var userInfo: @Sendable (String, String) async throws -> ActualSyncRemoteFile? {
        { _, _ in nil }
    }
}
