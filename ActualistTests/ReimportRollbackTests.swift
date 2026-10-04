import Foundation
import Testing
@testable import Actualist

/// A failed reimport swap must never leave the budget without a live
/// directory, and a backup that is the only copy must never be deleted.
@MainActor
@Suite("Reimport rollback")
struct ReimportRollbackTests {
    private let support = LocalFirstActualStoreTests()

    private struct Fixture {
        let fileSystem: FailingFileManager
        let files: BudgetFileManager
        let live: URL
    }

    private func makeFixture() throws -> Fixture {
        let fileSystem = FailingFileManager()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ReimportRollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files = BudgetFileManager(applicationSupportURL: root, fileManager: fileSystem)
        let live = try files.budgetDirectory(fileID: "file-1")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: live.appending(path: "db.sqlite"))
        return Fixture(fileSystem: fileSystem, files: files, live: live)
    }

    private func stage(_ fixture: Fixture) throws -> BudgetReimportWorkspace {
        let workspace = try fixture.files.prepareReimportWorkspace(fileID: "file-1")
        try Data("replacement".utf8).write(to: workspace.databaseURL)
        return workspace
    }

    private func liveContents(_ fixture: Fixture) -> String? {
        (try? Data(contentsOf: fixture.live.appending(path: "db.sqlite")))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private func failSwapAndRestore(_ fixture: Fixture) {
        fixture.fileSystem.rules.withLock {
            $0.failMove = { source, _ in
                FailingFileManager.isStagedSwap(source) || FailingFileManager.isBackupRestore(source)
            }
        }
    }

    @Test func failedSwapRestoresTheBackupAsTheLiveBudget() throws {
        let fixture = try makeFixture()
        let workspace = try stage(fixture)
        fixture.fileSystem.rules.withLock { $0.failMove = { source, _ in FailingFileManager.isStagedSwap(source) } }

        #expect(throws: LocalFirstTestSyncError.failed) {
            try fixture.files.commitReimport(workspace, fileID: "file-1")
        }

        #expect(liveContents(fixture) == "original")
        #expect(try !fixture.files.reimportBackupExists(fileID: "file-1"))
    }

    @Test func failedSwapAndFailedRestoreThrowTheTypedErrorAndKeepTheBackup() throws {
        let fixture = try makeFixture()
        let workspace = try stage(fixture)
        failSwapAndRestore(fixture)

        #expect(throws: LocalFirstError.reimportRollbackFailed) {
            try fixture.files.commitReimport(workspace, fileID: "file-1")
        }

        // Positive control: the swap really moved the live budget aside.
        #expect(!FileManager.default.fileExists(atPath: fixture.live.path))
        #expect(try fixture.files.reimportBackupExists(fileID: "file-1"))
    }

    @Test func nextOpenRestoresABackupWhenTheLiveDirectoryIsMissing() throws {
        let fixture = try makeFixture()
        let workspace = try stage(fixture)
        failSwapAndRestore(fixture)
        #expect(throws: LocalFirstError.reimportRollbackFailed) {
            try fixture.files.commitReimport(workspace, fileID: "file-1")
        }
        fixture.fileSystem.rules.withLock { $0.failMove = nil }

        #expect(fixture.files.importedDatabaseExists(fileID: "file-1"))

        #expect(liveContents(fixture) == "original")
        #expect(try !fixture.files.reimportBackupExists(fileID: "file-1"))
    }

    @Test func laterReimportDoesNotDeleteTheOnlyCopy() throws {
        let fixture = try makeFixture()
        let first = try stage(fixture)
        failSwapAndRestore(fixture)
        #expect(throws: LocalFirstError.reimportRollbackFailed) {
            try fixture.files.commitReimport(first, fileID: "file-1")
        }
        fixture.fileSystem.rules.withLock { $0.failMove = nil }
        let secondDirectory = fixture.live.deletingLastPathComponent()
            .appending(path: "\(fixture.live.lastPathComponent).reimport-second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try Data("second".utf8).write(to: secondDirectory.appending(path: "db.sqlite"))
        let second = BudgetReimportWorkspace(
            directoryURL: secondDirectory,
            archiveURL: secondDirectory.appending(path: "download.staging"),
            databaseURL: secondDirectory.appending(path: "db.sqlite"),
            metadataURL: secondDirectory.appending(path: "metadata.json")
        )

        try fixture.files.commitReimport(second, fileID: "file-1")

        #expect(liveContents(fixture) == "second")
        let backup = fixture.live.deletingLastPathComponent()
            .appending(path: ".ReimportBackups", directoryHint: .isDirectory)
            .appending(path: fixture.live.lastPathComponent, directoryHint: .isDirectory)
        let kept = try Data(contentsOf: backup.appending(path: "db.sqlite"))
        #expect(String(data: kept, encoding: .utf8) == "original")
    }

    @Test func storeReopensTheOldBudgetAfterAFailedSwap() async throws {
        let (bundle, fileSystem) = try await makeStoreBundle()
        fileSystem.rules.withLock { $0.failMove = { source, _ in FailingFileManager.isStagedSwap(source) } }

        await #expect(throws: LocalFirstTestSyncError.failed) {
            try await bundle.store.reimportBudget(bundle.budget, serverURLString: "https://sync.example")
        }

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let accounts = bundle.store.accountDisplays(budgetID: "group-1").map(\.account.id)
        #expect(!accounts.contains("replacement"))
        #expect(!(try bundle.fileManager.reimportBackupExists(fileID: "file-1")))
    }

    @Test func storeKeepsTheBackupWhenSwapAndRestoreFailThenRestoresOnNextOpen() async throws {
        let (bundle, fileSystem) = try await makeStoreBundle()
        fileSystem.rules.withLock {
            $0.failMove = { source, _ in
                FailingFileManager.isStagedSwap(source) || FailingFileManager.isBackupRestore(source)
            }
        }

        await #expect(throws: LocalFirstError.reimportRollbackFailed) {
            try await bundle.store.reimportBudget(bundle.budget, serverURLString: "https://sync.example")
        }

        #expect(try bundle.fileManager.reimportBackupExists(fileID: "file-1"))
        #expect(!bundle.store.isOpen(budgetID: "group-1"))
        fileSystem.rules.withLock { $0.failMove = nil }
        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(!bundle.store.accountDisplays(budgetID: "group-1").map(\.account.id).contains("replacement"))
    }

    private func makeStoreBundle() async throws -> (LocalFirstActualStoreTests.OpenedWritableStoreBundle, FailingFileManager) {
        let archive = try support.makeArchiveData(
            databaseURL: support.makeSQLiteFixture(
                extraSQL: "INSERT INTO accounts VALUES ('replacement', 'Replacement', 0, 0, 0, 2)"
            )
        )
        let transport = StubConnectionTransport(
            files: [support.testRemoteFile()],
            token: "reimport-token",
            downloadData: archive
        )
        let fileSystem = FailingFileManager()
        let bundle = try await support.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { _ in transport },
            budgetFileManager: fileSystem
        )
        try bundle.keychain.saveActualSyncToken("reimport-token")
        return (bundle, fileSystem)
    }
}
