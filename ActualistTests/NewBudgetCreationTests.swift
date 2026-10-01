import Foundation
import GRDB
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
    private func makeStore() -> (store: LocalFirstActualStore, fileManager: BudgetFileManager) {
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: FakeKeychainBackend()
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NewBudget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
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
        #expect(await transport.events == ["upload", "createKey"])
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
    private(set) var uploads: [UploadCall] = []
    private(set) var createKeyCalls: [CreateKeyCall] = []
    private(set) var events: [String] = []

    init(
        uploadResults: [Result<ActualUploadUserFileResponse, Error>] = [],
        createKeyError: Error? = nil
    ) {
        self.uploadResults = uploadResults
        self.createKeyError = createKeyError
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
}

/// Lock-protected fake for the existing list-user-files / get-user-file-info
/// recovery paths, with the same sticky-last queue semantics.
private final class NewBudgetRegistrationRecoveryStub: @unchecked Sendable {
    private let lock = NSLock()
    private var listResults: [Result<[ActualSyncRemoteFile], Error>]

    init(listResults: [Result<[ActualSyncRemoteFile], Error>] = []) {
        self.listResults = listResults
    }

    var listUserFiles: @Sendable (String) async throws -> [ActualSyncRemoteFile] {
        { [self] _ in
            try lock.withLock {
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
