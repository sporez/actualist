import Foundation
import Testing
@testable import Actualist

/// Settings portable export coverage: the refusal when no budget is open and
/// a produced archive the existing `PortableBudgetArchive` validator accepts.
@Suite @MainActor
struct PortableBudgetExportTests {
    private let support = LocalFirstActualStoreTests()

    @Test func exportIsRefusedWhenNoBudgetIsOpen() async throws {
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "PortableExport-closed-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let store = LocalFirstActualStore(keychain: keychain, fileManager: fileManager)

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await store.exportPortableBudgetArchive(budgetID: "file-1")
        }
    }

    @Test func exportProducesArchiveThePortableValidatorAccepts() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        // A scratch export directory keeps a concurrent sign-out test from
        // sweeping this test's archive out of the shared tmp directory.
        bundle.store.portableExportFiles = PortableExportFiles(
            temporaryDirectory: FileManager.default.temporaryDirectory
                .appending(path: "PortableExport-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        )

        // The store's open-budget identity is the budget's sync ID
        // (group ID, with the cloud file ID as fallback), matching
        // `openedBudgetID` and the production caller's `selectedBudgetID`.
        let archiveURL = try await bundle.store.exportPortableBudgetArchive(
            budgetID: bundle.budget.syncID
        )
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))

        let staging = FileManager.default.temporaryDirectory
            .appending(path: "PortableExport-validate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let validated = try PortableBudgetArchive().validate(
            archiveAt: archiveURL,
            stagingDirectory: staging
        )

        // The archive is a fresh portable identity, not the source budget's.
        #expect(validated.metadata.budgetName == "Writable Budget")
        #expect(validated.metadata.resetClock == true)
        #expect(validated.metadata.id != bundle.budget.budgetID)
        #expect(!validated.metadata.id.isEmpty)
        #expect(FileManager.default.fileExists(atPath: validated.databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: validated.metadataURL.path))
    }
}
