import Foundation
import Testing
@testable import Actualist

/// Plaintext export ZIP lifecycle: where it is written, the two-step
/// prepare-then-share workflow, the share item, and when files are removed
/// (reset, supersession, sign-out, age).
@Suite @MainActor
struct PortableBudgetExportLifecycleTests {
    private let support = LocalFirstActualStoreTests()

    private func makeScratchFiles() -> PortableExportFiles {
        PortableExportFiles(
            temporaryDirectory: FileManager.default.temporaryDirectory
                .appending(path: "ExportLifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
    }

    private func makeBundle() async throws -> (
        bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle,
        files: PortableExportFiles
    ) {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let files = makeScratchFiles()
        bundle.store.portableExportFiles = files
        return (bundle, files)
    }

    private func age(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func exportIsWrittenInsideTheExportDirectory() async throws {
        let (bundle, files) = try await makeBundle()

        let url = try await bundle.store.exportPortableBudgetArchive(budgetID: bundle.budget.syncID)

        #expect(url.deletingLastPathComponent().standardizedFileURL == files.directory.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func prepareBuildsAValidArchiveForTheBudget() async throws {
        let (bundle, files) = try await makeBundle()
        let store = bundle.store
        let workflow = PortableBudgetExportWorkflow(files: files)
        let budgetID = bundle.budget.syncID

        await workflow.prepare(budgetID: budgetID) { try await store.exportPortableBudgetArchive(budgetID: $0) }

        let url = try #require(workflow.readyArchive(for: budgetID))
        #expect(workflow.readyArchive(for: "another-budget") == nil)
        #expect(url.deletingLastPathComponent().standardizedFileURL == files.directory.standardizedFileURL)
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "WorkflowValidate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let validated = try PortableBudgetArchive().validate(archiveAt: url, stagingDirectory: staging)
        #expect(validated.metadata.budgetName == "Writable Budget")
    }

    @Test func prepareForANonOpenBudgetFailsWithoutLeavingAnArchive() async throws {
        let (bundle, files) = try await makeBundle()
        let store = bundle.store
        let workflow = PortableBudgetExportWorkflow(files: files)

        await workflow.prepare(budgetID: "a-budget-that-is-not-open") {
            try await store.exportPortableBudgetArchive(budgetID: $0)
        }

        guard case .failed = workflow.state else {
            Issue.record("Expected a failed export, got \(workflow.state)")
            return
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: files.directory.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func resetAndRepreparingDiscardTheReadyArchive() async throws {
        let (bundle, files) = try await makeBundle()
        let store = bundle.store
        let workflow = PortableBudgetExportWorkflow(files: files)
        let budgetID = bundle.budget.syncID
        let export: @MainActor (String) async throws -> URL = { try await store.exportPortableBudgetArchive(budgetID: $0) }

        await workflow.prepare(budgetID: budgetID, export: export)
        let first = try #require(workflow.readyArchive(for: budgetID))
        await workflow.prepare(budgetID: budgetID, export: export)
        let second = try #require(workflow.readyArchive(for: budgetID))
        #expect(!FileManager.default.fileExists(atPath: first.path))

        workflow.reset()

        #expect(workflow.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aBuildFinishingAfterResetIsDiscarded() async throws {
        let (bundle, files) = try await makeBundle()
        let store = bundle.store
        let workflow = PortableBudgetExportWorkflow(files: files)
        var finishedURL: URL?

        await workflow.prepare(budgetID: bundle.budget.syncID) { budgetID in
            let url = try await store.exportPortableBudgetArchive(budgetID: budgetID)
            finishedURL = url
            workflow.reset()
            return url
        }

        #expect(workflow.state == .idle)
        let url = try #require(finishedURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func shareItemStartsAppSwitcherSuppressionOnlyWhenRequested() async throws {
        let (bundle, _) = try await makeBundle()
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let appState = AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: bundle.keychain,
            localFirstStore: bundle.store
        )
        appState.updateAppSwitcherPrivacyMode(.always)
        let archiveURL = URL(fileURLWithPath: "/tmp/ready.zip")
        let transfer = PortableBudgetArchiveTransfer.make(archiveURL: archiveURL, appState: appState)
        #expect(!appState.isAppSwitcherCoverSuppressedForSystemUI)

        let shared = await transfer.exportArchive()

        #expect(shared == archiveURL)
        #expect(appState.isAppSwitcherCoverSuppressedForSystemUI)
        appState.clearAppInitiatedSystemUIPresentationSuppression()
    }

    /// On iPhone the temporary directory sits under `/var`, a symlink to
    /// `/private/var`. A staging directory reached through a symlink must
    /// still accept the export's own entries.
    @Test func validationAcceptsAStagingDirectoryReachedThroughASymlink() async throws {
        let (bundle, _) = try await makeBundle()
        let url = try await bundle.store.exportPortableBudgetArchive(budgetID: bundle.budget.syncID)
        let base = FileManager.default.temporaryDirectory
            .appending(path: "SymlinkStage-\(UUID().uuidString)", directoryHint: .isDirectory)
        let real = base.appending(path: "real", directoryHint: .isDirectory)
        let alias = base.appending(path: "alias", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let validated = try PortableBudgetArchive().validate(archiveAt: url, stagingDirectory: alias)

        #expect(validated.metadata.budgetName == "Writable Budget")
    }

    @Test func everyArchiveRejectionHasAPlainMessage() {
        let reasons: [PortableBudgetArchiveError.Reason] = [
            .unsafePath, .symbolicLink, .resourceLimit, .insufficientStorage, .truncated,
            .missingDatabase, .missingMetadata, .splitDirectories, .ambiguous, .checksumMismatch,
            .malformedMetadata, .oversizedMetadata, .integrity, .unsupportedSchema,
        ]
        for reason in reasons {
            let message = PortableBudgetArchiveError(stage: .beforeInstall, reason: reason).localizedDescription
            #expect(!message.contains("PortableBudgetArchiveError"), "\(reason): \(message)")
            #expect(!message.contains("couldn’t be completed"), "\(reason): \(message)")
        }
    }

    @Test func sweepKeepsFreshFilesAndRemovesStaleOnes() throws {
        let files = makeScratchFiles()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fresh = try files.makeArchiveURL()
        let stale = try files.makeArchiveURL()
        try Data("fresh".utf8).write(to: fresh)
        try Data("stale".utf8).write(to: stale)
        try age(fresh, to: now.addingTimeInterval(-9 * 60))
        try age(stale, to: now.addingTimeInterval(-11 * 60))

        files.sweepStale(now: now)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func exportSweepsStaleFilesBeforeWriting() async throws {
        let (bundle, files) = try await makeBundle()
        let stale = try files.makeArchiveURL()
        try Data("old".utf8).write(to: stale)
        try age(stale, to: Date().addingTimeInterval(-3_600))

        _ = try await bundle.store.exportPortableBudgetArchive(budgetID: bundle.budget.syncID)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func eraseLocalDataRemovesEveryExport() async throws {
        let (bundle, files) = try await makeBundle()
        let url = try await bundle.store.exportPortableBudgetArchive(budgetID: bundle.budget.syncID)
        #expect(FileManager.default.fileExists(atPath: url.path))

        try await bundle.store.eraseLocalData()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: files.directory.path)) ?? []).isEmpty)
    }

    @Test func discardIgnoresFilesOutsideTheExportDirectory() throws {
        let files = makeScratchFiles()
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "outside-\(UUID().uuidString).zip")
        try Data("keep".utf8).write(to: outside)

        files.discard(outside)

        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func footerWarnsOnlyForEncryptedBudgets() {
        let plain = PortableBudgetArchiveTransfer.footerText(isBudgetEncrypted: false)
        let encrypted = PortableBudgetArchiveTransfer.footerText(isBudgetEncrypted: true)

        #expect(!plain.contains("not encrypted"))
        #expect(encrypted.hasPrefix(plain))
        #expect(encrypted.contains("This export is not encrypted. Anyone with the file can read your budget."))
    }

    @Test func openBudgetEncryptionFollowsTheOpenedContext() async throws {
        let (bundle, _) = try await makeBundle()
        #expect(!bundle.store.isOpenBudgetEncrypted)

        bundle.store.openedEncryptionContext = ActualBudgetEncryptionContext(
            keyID: "key-1",
            keyData: Data(repeating: 1, count: 32)
        )

        #expect(bundle.store.isOpenBudgetEncrypted)
    }
}
