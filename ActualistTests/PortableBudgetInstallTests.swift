import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import Actualist

/// Portable-budget install coverage: BudgetFileManager's new-directory
/// install for an already validated pair, and the store's portable-import
/// flow (validate → mint one file ID → install → register → confirmed
/// metadata, with no-selectable-budget-on-failure cleanup). Everything runs
/// against synthetic seed bytes and a fake registration transport; no demo or
/// user budget bytes, no server, no `importBudgetZip` / `reimportBudget`.
@MainActor
struct PortableBudgetInstallTests {
    // MARK: - Fixtures

    private func makeFixture() -> (
        fileManager: BudgetFileManager,
        store: LocalFirstActualStore,
        rootURL: URL
    ) {
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: FakeKeychainBackend()
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "PortableInstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let store = LocalFirstActualStore(keychain: keychain, fileManager: fileManager)
        return (fileManager, store, rootURL)
    }

    private func makeStagedPair(in root: URL) throws -> (databaseURL: URL, metadataURL: URL) {
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let databaseURL = staging.appending(path: "db.sqlite")
        let metadataURL = staging.appending(path: "metadata.json")
        try FileManager.default.copyItem(at: try Self.makeSeedDatabaseURL(), to: databaseURL)
        try Self.metadataJSON().write(to: metadataURL)
        return (databaseURL, metadataURL)
    }

    private func makePortableZip(in root: URL) throws -> (url: URL, bytes: Data) {
        let zipURL = root.appending(path: "portable.zip")
        try Self.writeZip(at: zipURL, files: [
            ("db.sqlite", try Data(contentsOf: try Self.makeSeedDatabaseURL())),
            ("metadata.json", try Self.metadataJSON())
        ])
        return (zipURL, try Data(contentsOf: zipURL))
    }

    private func makeIdentitySequence(prefix: String) -> @Sendable () -> String {
        let sequence = IdentitySequence(prefix: prefix)
        return { sequence.generate() }
    }

    // MARK: - New-directory install

    @Test func installWritesValidatedPairIntoNewBudgetDirectory() throws {
        let (fileManager, _, rootURL) = makeFixture()
        let staged = try makeStagedPair(in: rootURL)
        let fileID = "install-file-1"

        try fileManager.installValidatedPortableBudget(
            databaseAt: staged.databaseURL,
            metadataAt: staged.metadataURL,
            fileID: fileID
        )

        let directory = try fileManager.budgetDirectory(fileID: fileID)
        let installedDatabase = directory.appending(path: "db.sqlite")
        let installedMetadata = directory.appending(path: "metadata.json")
        let installedDatabaseBytes = try Data(contentsOf: installedDatabase)
        let stagedDatabaseBytes = try Data(contentsOf: staged.databaseURL)
        let installedMetadataBytes = try Data(contentsOf: installedMetadata)
        let stagedMetadataBytes = try Data(contentsOf: staged.metadataURL)
        #expect(installedDatabaseBytes == stagedDatabaseBytes)
        #expect(installedMetadataBytes == stagedMetadataBytes)
        #expect(fileManager.importedDatabaseExists(fileID: fileID))
    }

    @Test func installRefusesExistingDirectoryWithoutDeletingIt() throws {
        let (fileManager, _, rootURL) = makeFixture()
        let staged = try makeStagedPair(in: rootURL)
        let fileID = "collision-file-1"
        let directory = try fileManager.budgetDirectory(fileID: fileID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinelURL = directory.appending(path: "sentinel.txt")
        try Data("keep".utf8).write(to: sentinelURL)

        #expect(throws: NewBudgetError.budgetDirectoryAlreadyExists) {
            try fileManager.installValidatedPortableBudget(
                databaseAt: staged.databaseURL,
                metadataAt: staged.metadataURL,
                fileID: fileID
            )
        }

        #expect(FileManager.default.fileExists(atPath: sentinelURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "db.sqlite").path
        ))
    }

    // MARK: - Portable import flow

    @Test func importRegistersMintedFileIDAndInstallsConfirmedMetadata() async throws {
        let (fileManager, store, rootURL) = makeFixture()
        let identities = makeIdentitySequence(prefix: "import")
        let transport = PortableImportFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-imported"))]
        )
        let zip = try makePortableZip(in: rootURL)

        let creation = try await store.importPortableBudget(
            archiveAt: zip.url,
            serverURLString: "https://portable-import.example",
            token: "session-token",
            registrationTransport: transport,
            identityGenerator: identities
        )

        // Registration happens once, under the same minted file ID the local
        // install used, and uploads the sanitized archive rebuilt from the
        // validated pair — never the raw user zip, whose embedded identity
        // must not reach the server.
        let uploads = await transport.uploads
        #expect(uploads.count == 1)
        #expect(uploads[0].fileID == creation.fileID)
        #expect(uploads[0].fileID == "import-1")
        #expect(uploads[0].name == "Portable Import Budget")
        #expect(uploads[0].bytes != zip.bytes)

        // The uploaded bytes are a valid portable archive: allowlisted,
        // fresh-identity metadata and the user's own database rows.
        let work = FileManager.default.temporaryDirectory
            .appending(path: "PortableImport-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let uploadedURL = work.appending(path: "uploaded.zip")
        try uploads[0].bytes.write(to: uploadedURL)
        let validated = try PortableBudgetArchive().validate(
            archiveAt: uploadedURL,
            stagingDirectory: work
        )
        #expect(validated.metadata.budgetName == "Portable Import Budget")
        #expect(validated.metadata.id != "source-cloud-file")
        #expect(validated.metadata.resetClock == true)
        var configuration = Configuration()
        configuration.readonly = true
        let uploadedDatabase = try DatabaseQueue(
            path: validated.databaseURL.path,
            configuration: configuration
        )
        try await uploadedDatabase.read { db in
            let groupNames = try String.fetchAll(db, sql: "SELECT name FROM category_groups")
            #expect(groupNames == ["Everyday"])
            let transactionCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions")
            #expect(transactionCount == 1)
        }

        // The installed directory carries the receipt's group identity and
        // scans as a locally selectable budget.
        let metadata = try #require(try fileManager.loadMetadata(fileID: creation.fileID))
        #expect(metadata.cloudFileID == creation.fileID)
        #expect(metadata.groupID == "group-imported")
        #expect(metadata.budgetName == "Portable Import Budget")
        #expect(metadata.encryptionKeyID == nil)
        #expect(fileManager.importedDatabaseExists(fileID: creation.fileID))
        #expect(try fileManager.importedBudgetFileIDs() == [creation.fileID])
    }

    @Test func registrationFailureDeletesTheNewDirectory() async throws {
        let (fileManager, store, rootURL) = makeFixture()
        let identities = makeIdentitySequence(prefix: "import")
        let transport = PortableImportFakeRegistrationTransport(
            uploadResults: [.failure(ActualAPIError.transport(.timedOut))]
        )
        let zip = try makePortableZip(in: rootURL)

        await #expect(throws: ActualFileRegistrationError.uploadUnconfirmed) {
            try await store.importPortableBudget(
                archiveAt: zip.url,
                serverURLString: "https://portable-import.example",
                token: "session-token",
                registrationTransport: transport,
                listUserFiles: { _ in [] },
                userInfo: { _, _ in nil },
                identityGenerator: identities
            )
        }

        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
    }

    @Test func existingBudgetDirectoryIsRefusedWithoutDeletingIt() async throws {
        let (fileManager, store, _) = makeFixture()
        let collidingIdentity: @Sendable () -> String = { "collision-id" }
        let directory = try fileManager.budgetDirectory(fileID: collidingIdentity())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinelURL = directory.appending(path: "sentinel.txt")
        try Data("keep".utf8).write(to: sentinelURL)
        let transport = PortableImportFakeRegistrationTransport()

        await #expect(throws: NewBudgetError.budgetDirectoryAlreadyExists) {
            try await store.importPortableBudget(
                archiveAt: URL(fileURLWithPath: "/nonexistent/portable.zip"),
                serverURLString: "https://portable-import.example",
                token: "session-token",
                registrationTransport: transport,
                identityGenerator: collidingIdentity
            )
        }

        #expect(FileManager.default.fileExists(atPath: sentinelURL.path))
        #expect(await transport.uploads.isEmpty)
    }

    @Test func invalidArchiveIsRefusedBeforeAnythingIsInstalled() async throws {
        let (fileManager, store, rootURL) = makeFixture()
        let zipURL = rootURL.appending(path: "invalid.zip")
        try Self.writeZip(at: zipURL, files: [("metadata.json", try Self.metadataJSON())])
        let transport = PortableImportFakeRegistrationTransport()

        await #expect(
            throws: PortableBudgetArchiveError(stage: .beforeInstall, reason: .missingDatabase)
        ) {
            try await store.importPortableBudget(
                archiveAt: zipURL,
                serverURLString: "https://portable-import.example",
                token: "session-token",
                registrationTransport: transport
            )
        }

        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
    }
}

// MARK: - Fakes

/// Locked deterministic identity sequence for the file ID.
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
/// paths. Captures full upload bytes.
private actor PortableImportFakeRegistrationTransport: ActualFileRegistrationTransport {
    struct UploadCall: Equatable {
        let fileID: String
        let name: String
        let bytes: Data
        let token: String
    }

    private var uploadResults: [Result<ActualUploadUserFileResponse, Error>]
    private(set) var uploads: [UploadCall] = []

    init(uploadResults: [Result<ActualUploadUserFileResponse, Error>] = []) {
        self.uploadResults = uploadResults
    }

    func uploadUserFile(
        fileID: String,
        name: String,
        groupID: String?,
        encryptMeta: ActualEncryptedMetadata?,
        bytes: Data,
        token: String
    ) async throws -> ActualUploadUserFileResponse {
        uploads.append(UploadCall(fileID: fileID, name: name, bytes: bytes, token: token))
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
        Issue.record("Plaintext portable imports never register an encryption key")
    }
}

extension PortableBudgetInstallTests {
    // MARK: - Seed bytes

    /// Synthetic seed satisfying the portable integrity gate: the four
    /// required domain tables with the required columns. Values are
    /// synthetic; no demo or user budget bytes.
    private static func makeSeedDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PortableInstall-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE category_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, acct TEXT, date INTEGER, amount INTEGER
                );
                INSERT INTO accounts VALUES ('checking', 'Checking');
                INSERT INTO category_groups VALUES ('group-1', 'Everyday');
                INSERT INTO categories VALUES ('groceries', 'Groceries');
                INSERT INTO transactions VALUES ('txn-1', 'checking', 20260901, -12345);
                """)
        }
        return url
    }

    private static func metadataJSON() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "id": "source-cloud-file",
                "budgetName": "Portable Import Budget",
                "resetClock": true
            ],
            options: [.sortedKeys]
        )
    }

    private static func writeZip(at url: URL, files: [(String, Data)]) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
                // payload per chunk and corrupts the stored CRC.
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
    }
}
