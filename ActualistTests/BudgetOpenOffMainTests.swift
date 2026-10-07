import Foundation
import Testing
@testable import Actualist

/// Concurrency remediation 4.2: the open, reimport-validation and New Budget
/// seed paths construct `BudgetDatabase` (SQLite open, compatibility passes,
/// index creation, history replays) off the main thread. `BudgetDatabase.init`
/// records main-thread constructions in DEBUG builds; fixtures call `init`
/// directly, so these tests look only at paths under their own store root.
@MainActor
@Suite("Budget open off main")
struct BudgetOpenOffMainTests {
    private let support = LocalFirstActualStoreTests()

    private func mainThreadConstructions(under root: URL) -> [String] {
        BudgetDatabase.debugMainThreadConstructionPaths.withLock { paths in
            paths.filter { $0.contains(root.lastPathComponent) }.sorted()
        }
    }

    @Test func openingAnImportedBudgetBuildsTheDatabaseOffTheMainThread() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle()

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(mainThreadConstructions(under: bundle.fileManager.applicationSupportURL).isEmpty)
    }

    @Test func reimportValidationAndReopenBuildTheDatabaseOffTheMainThread() async throws {
        let replacementURL = try support.makeSQLiteFixture(
            extraSQL: "INSERT INTO accounts VALUES ('replacement', 'Replacement', 0, 0, 0, 2)"
        )
        let transport = StubConnectionTransport(
            files: [support.testRemoteFile()],
            token: "reimport-token",
            downloadData: try support.makeArchiveData(databaseURL: replacementURL)
        )
        let bundle = try await support.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("reimport-token")

        try await bundle.store.reimportBudget(bundle.budget, serverURLString: "https://sync.example")

        let onMain = mainThreadConstructions(under: bundle.fileManager.applicationSupportURL)
        #expect(onMain.filter { $0.contains(".reimport-") }.isEmpty)
        #expect(onMain.isEmpty)
    }

    @Test func newBudgetSeedBuildsTheDatabaseOffTheMainThread() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "NewBudgetOffMain-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL, fileManager: .default)
        let store = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString,
                backend: FakeKeychainBackend()
            ),
            fileManager: fileManager
        )
        let transport = NewBudgetFakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-new"))]
        )

        _ = try await store.createNewBudget(
            named: "Off Main",
            serverURLString: "https://newbudget.example",
            token: "session-token",
            registrationTransport: transport
        )

        #expect(mainThreadConstructions(under: rootURL).isEmpty)
    }
}
