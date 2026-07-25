import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func budgetFileManagerHashesAndValidatesServerFileIDs() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetPaths-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)

        for fileID in ["", ".", "..", "../..", "%2e%2e%2f..", "bad\0id"] {
            #expect(throws: LocalFirstError.invalidBudgetFileID) {
                _ = try fileManager.budgetDirectory(fileID: fileID)
            }
        }

        let longID = String(repeating: "budget-", count: 10_000)
        let directory = try fileManager.budgetDirectory(fileID: longID)
        #expect(directory.lastPathComponent.count == 64)
        #expect(!directory.path.contains(longID))
    }

    @Test func budgetFileManagerRejectsSymlinkEscapeFromBudgetRoot() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetSymlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let supportURL = baseURL.appending(path: "support", directoryHint: .isDirectory)
        let outsideURL = baseURL.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: supportURL.appending(path: "Budgets"),
            withDestinationURL: outsideURL
        )

        let fileManager = BudgetFileManager(applicationSupportURL: supportURL)
        #expect(throws: LocalFirstError.invalidBudgetFileID) {
            _ = try fileManager.databaseURL(fileID: "safe-id")
        }
    }

    @Test func importedBudgetDiscoveryReturnsMetadataFileIDNotHashedDirectoryName() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetDiscovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let fileID = "server-file-id"
        let directory = try fileManager.budgetDirectory(fileID: fileID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: nil,
            budgetName: "Budget",
            encryptionKeyID: nil,
            nodeID: "node"
        )
        try JSONEncoder.actual.encode(metadata).write(to: fileManager.metadataURL(fileID: fileID))

        #expect(try fileManager.importedBudgetFileIDs() == [fileID])
    }

    @Test func budgetArchiveImportAcceptsAValidStagedArchive() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetArchive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(
            applicationSupportURL: rootURL,
            resourceLimits: testResourceLimits()
        )
        let stagingURL = try fileManager.prepareDownloadStaging(fileID: "file-1")
        try makeArchive(at: stagingURL, entries: [("nested/db.sqlite", Data("sqlite".utf8))])

        let databaseURL = try fileManager.importBudgetZip(
            at: stagingURL,
            remoteFile: testRemoteFile(),
            metadata: testBudgetMetadata()
        )

        #expect(try Data(contentsOf: databaseURL) == Data("sqlite".utf8))
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test func cachedBudgetHardeningReappliesEffectiveSecurityToEveryArtifact() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetHardening-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let directory = try fileManager.budgetDirectory(fileID: "file-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let database = try fileManager.databaseURL(fileID: "file-1")
        let metadata = try fileManager.metadataURL(fileID: "file-1")
        let artifacts = [
            directory,
            database,
            metadata,
            directory.appending(path: "db.sqlite-wal"),
            directory.appending(path: "db.sqlite-shm"),
            directory.appending(path: "db.sqlite-journal")
        ]
        for artifact in artifacts.dropFirst() {
            #expect(FileManager.default.createFile(atPath: artifact.path, contents: Data()))
        }
        for artifact in artifacts {
            try markBudgetArtifactAsUnhardened(artifact)
        }

        #expect(
            Set(try fileManager.cachedBudgetArtifacts(fileID: "file-1").map(\.lastPathComponent))
                == Set([
                    directory.lastPathComponent,
                    "db.sqlite",
                    "metadata.json",
                    "db.sqlite-wal",
                    "db.sqlite-shm",
                    "db.sqlite-journal"
                ])
        )
        try fileManager.hardenCachedBudget(fileID: "file-1")

        for artifact in artifacts {
            try expectBudgetArtifactIsHardened(artifact)
        }
    }

    @Test func openingCachedBudgetRunsHardeningBeforeAndAfterDatabaseOpen() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistCachedOpenHardening-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let fileID = "file-1"
        let directory = try fileManager.budgetDirectory(fileID: fileID)
        let database = try fileManager.databaseURL(fileID: fileID)
        let metadata = try fileManager.metadataURL(fileID: fileID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: makeSQLiteFixture(),
            to: database
        )
        try JSONEncoder.actual.encode(testBudgetMetadata())
            .write(to: metadata)
        for artifact in [directory, database, metadata] {
            try markBudgetArtifactAsUnhardened(artifact)
        }
        let store = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            ),
            fileManager: fileManager
        )

        #expect(
            try await store.openCachedBudget(
                ActualBudget(
                    budgetID: fileID,
                    cloudFileId: fileID,
                    groupId: "group-1",
                    name: "Budget",
                    state: nil
                )
            )
        )

        let sidecars = ["-wal", "-shm", "-journal"].map {
            directory.appending(path: "db.sqlite\($0)")
        }
        for artifact in [directory, database, metadata]
            + sidecars.filter({ FileManager.default.fileExists(atPath: $0.path) }) {
            try expectBudgetArtifactIsHardened(artifact)
        }
    }

    @Test func budgetArchiveImportRejectsZipSlipAndEveryArchiveQuota() throws {
        struct ArchiveCase {
            let name: String
            let limits: LocalFirstResourceLimits
            let entries: [(String, Data)]
            let expectedError: LocalFirstError
        }

        let cases = [
            ArchiveCase(
                name: "zip-slip",
                limits: testResourceLimits(),
                entries: [("../escape/db.sqlite", Data("sqlite".utf8))],
                expectedError: .invalidDownloadedBudget
            ),
            ArchiveCase(
                name: "absolute",
                limits: testResourceLimits(),
                entries: [("/escape/db.sqlite", Data("sqlite".utf8))],
                expectedError: .invalidDownloadedBudget
            ),
            ArchiveCase(
                name: "entry-size",
                limits: testResourceLimits(maximumArchiveEntryBytes: 4),
                entries: [("db.sqlite", Data("12345".utf8))],
                expectedError: .remoteDataLimitExceeded
            ),
            ArchiveCase(
                name: "expanded-size",
                limits: testResourceLimits(maximumExpandedBudgetBytes: 6),
                entries: [("first", Data("1234".utf8)), ("db.sqlite", Data("5678".utf8))],
                expectedError: .remoteDataLimitExceeded
            ),
            ArchiveCase(
                name: "entry-count",
                limits: testResourceLimits(maximumArchiveEntryCount: 1),
                entries: [("first", Data("1".utf8)), ("db.sqlite", Data("2".utf8))],
                expectedError: .remoteDataLimitExceeded
            ),
            ArchiveCase(
                name: "path-depth",
                limits: testResourceLimits(maximumArchivePathDepth: 2),
                entries: [("one/two/db.sqlite", Data("sqlite".utf8))],
                expectedError: .remoteDataLimitExceeded
            )
        ]

        for archiveCase in cases {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(
                    path: "ActualistBudgetArchive-\(archiveCase.name)-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            let fileManager = BudgetFileManager(
                applicationSupportURL: rootURL,
                resourceLimits: archiveCase.limits
            )
            let stagingURL = try fileManager.prepareDownloadStaging(fileID: "file-1")
            try makeArchive(at: stagingURL, entries: archiveCase.entries)

            #expect(throws: archiveCase.expectedError) {
                _ = try fileManager.importBudgetZip(
                    at: stagingURL,
                    remoteFile: testRemoteFile(),
                    metadata: testBudgetMetadata()
                )
            }
            #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
            let importDirectory = try fileManager.budgetDirectory(fileID: "file-1")
                .appending(path: "import")
            #expect(
                !FileManager.default.fileExists(
                    atPath: importDirectory.path
                )
            )
        }
    }

    @Test func stagedBudgetDownloadEnforcesCompressedSizeLimit() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistCompressedLimit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(
            applicationSupportURL: rootURL,
            resourceLimits: testResourceLimits(maximumCompressedBudgetBytes: 4)
        )
        let stagingURL = try fileManager.prepareDownloadStaging(fileID: "file-1")

        #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            try fileManager.replaceStagedDownload(
                at: stagingURL,
                with: Data(repeating: 0x41, count: 5)
            )
        }
    }

    @Test func failedInitialDownloadRemovesThePartialArchive() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistDownloadCleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        try keychain.saveActualSyncToken("token")
        let transport = StubConnectionTransport(
            failurePoint: .download,
            files: [testRemoteFile()],
            downloadData: Data("partial archive".utf8)
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            connectionTransportFactory: { _ in transport }
        )

        await #expect(throws: LocalFirstTestSyncError.failed) {
            try await store.openBudget(
                ActualBudget(
                    budgetID: "file-1",
                    cloudFileId: "file-1",
                    groupId: "group-1",
                    name: "Budget",
                    state: nil
                ),
                serverURLString: "https://sync.example"
            )
        }

        let directory = try fileManager.budgetDirectory(fileID: "file-1")
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "download.staging").path
            )
        )
    }

    @Test func serverSessionDoesNotCacheResponsesOrStoreCookies() async throws {
        let configuration = ActualServerSyncClient.secureSessionConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)

        configuration.protocolClasses = [CredentialStorageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let host = "credential-storage-\(UUID().uuidString).example"
        let baseURL = try #require(URL(string: "https://\(host)"))
        let requestURL = baseURL.appending(path: "sync/list-user-files")
        var cacheRequest = URLRequest(url: requestURL)
        cacheRequest.httpMethod = "GET"
        URLCache.shared.removeCachedResponse(for: cacheRequest)
        defer { URLCache.shared.removeCachedResponse(for: cacheRequest) }

        let sharedCookieStorage = HTTPCookieStorage.shared
        for cookie in sharedCookieStorage.cookies(for: baseURL) ?? [] {
            sharedCookieStorage.deleteCookie(cookie)
        }

        let client = ActualServerSyncClient(baseURL: baseURL, session: session)
        let files = try await client.listUserFiles(token: "sensitive-token")

        #expect(files.isEmpty)
        #expect(URLCache.shared.cachedResponse(for: cacheRequest) == nil)
        #expect(sharedCookieStorage.cookies(for: baseURL)?.isEmpty != false)
    }

    @Test func serverSendsOnlyActualTokenCredentialHeader() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialHeaderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ActualServerSyncClient(
            baseURL: URL(string: "https://credential-header.example")!,
            session: session
        )

        let files = try await client.listUserFiles(token: "sensitive-token")

        #expect(files.isEmpty)
    }

    @Test func serverBudgetDownloadStreamsToAFileAndRejectsOversizedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceLimitURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let limits = testResourceLimits(maximumCompressedBudgetBytes: 8)
        let destinationURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistDownload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let client = ActualServerSyncClient(
            baseURL: URL(string: "https://small-download.example")!,
            session: session,
            resourceLimits: limits
        )
        try await client.downloadUserFile(fileID: "file", token: "token", to: destinationURL)
        #expect(try Data(contentsOf: destinationURL) == Data("small".utf8))

        let oversizedClient = ActualServerSyncClient(
            baseURL: URL(string: "https://large-download.example")!,
            session: session,
            resourceLimits: limits
        )
        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            try await oversizedClient.downloadUserFile(
                fileID: "file",
                token: "token",
                to: destinationURL
            )
        }

        let oversizedSyncClient = ActualServerSyncClient(
            baseURL: URL(string: "https://chunked-sync.example")!,
            session: session,
            resourceLimits: testResourceLimits(maximumSyncResponseBytes: 8)
        )
        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            _ = try await oversizedSyncClient.sync(data: Data(), token: "token")
        }
    }

    @Test func syncClientRejectsOversizedTransportResponsesBeforeDecoding() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let client = SyncClient(
            resourceLimits: testResourceLimits(maximumSyncResponseBytes: 4)
        )
        await client.configure(
            LocalFirstSyncConfiguration(
                fileID: "file",
                groupID: nil,
                nodeID: "node",
                encryptionKeyID: nil,
                encryptionContext: nil
            )
        )

        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            _ = try await client.pullAndApply(
                database: database,
                client: FixedResponseSyncTransport(responseData: Data(repeating: 0, count: 5)),
                token: "token"
            )
        }
    }

}
