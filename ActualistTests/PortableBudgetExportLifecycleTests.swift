import Foundation
import Testing
@testable import Actualist

/// Plaintext export ZIP lifecycle: where it is written, and when it is removed
/// (sign-out, age) and the lazy share item that requests it.
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

    @MainActor private final class BeganCounter {
        var count = 0
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

    @Test func transferRequestBuildsArchiveForTheBoundBudget() async throws {
        let (bundle, files) = try await makeBundle()
        let store = bundle.store
        let began = BeganCounter()
        let transfer = PortableBudgetArchiveTransfer(
            budgetID: bundle.budget.syncID,
            willExport: { began.count += 1 },
            export: { budgetID in try await store.exportPortableBudgetArchive(budgetID: budgetID) }
        )

        let url = try await transfer.exportArchive()

        #expect(began.count == 1)
        #expect(url.deletingLastPathComponent().standardizedFileURL == files.directory.standardizedFileURL)
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "TransferValidate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let validated = try PortableBudgetArchive().validate(archiveAt: url, stagingDirectory: staging)
        #expect(validated.metadata.budgetName == "Writable Budget")
    }

    @Test func eachTransferRequestWritesItsOwnArchive() async throws {
        let (bundle, _) = try await makeBundle()
        let store = bundle.store
        let transfer = PortableBudgetArchiveTransfer(
            budgetID: bundle.budget.syncID,
            willExport: {},
            export: { budgetID in try await store.exportPortableBudgetArchive(budgetID: budgetID) }
        )

        let first = try await transfer.exportArchive()
        let second = try await transfer.exportArchive()

        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func transferForAnotherBudgetFailsWithoutWritingAnArchive() async throws {
        let (bundle, files) = try await makeBundle()
        let store = bundle.store
        let transfer = PortableBudgetArchiveTransfer(
            budgetID: "a-budget-that-is-not-open",
            willExport: {},
            export: { budgetID in try await store.exportPortableBudgetArchive(budgetID: budgetID) }
        )

        await #expect(throws: (any Error).self) {
            try await transfer.exportArchive()
        }

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: files.directory.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func transferPropagatesExportFailureAfterStartingSuppression() async {
        struct ExportFailure: Error {}
        let began = BeganCounter()
        let transfer = PortableBudgetArchiveTransfer(
            budgetID: "budget",
            willExport: { began.count += 1 },
            export: { _ in throw ExportFailure() }
        )

        await #expect(throws: ExportFailure.self) {
            try await transfer.exportArchive()
        }
        #expect(began.count == 1)
    }

    @Test func makeTriggersAppSwitcherSuppressionOnlyWhenRequested() async throws {
        let (bundle, _) = try await makeBundle()
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let appState = AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: bundle.keychain,
            localFirstStore: bundle.store
        )
        appState.updateAppSwitcherPrivacyMode(.always)
        let transfer = PortableBudgetArchiveTransfer.make(budgetID: bundle.budget.syncID, appState: appState)
        #expect(!appState.isAppSwitcherCoverSuppressedForSystemUI)

        _ = try await transfer.exportArchive()

        #expect(appState.isAppSwitcherCoverSuppressedForSystemUI)
        appState.clearAppInitiatedSystemUIPresentationSuppression()
        #expect(!appState.isAppSwitcherCoverSuppressedForSystemUI)
    }

    @Test func exportActivityCountsOverlappingRequestsAndNeverGoesNegative() {
        let activity = PortableBudgetExportActivity()
        #expect(!activity.isPreparing)
        activity.begin()
        activity.begin()
        activity.end()
        #expect(activity.isPreparing)
        activity.end()
        #expect(!activity.isPreparing)
        activity.end()
        #expect(activity.inFlightCount == 0)
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

    @Test func shareTapShowsPreparingUntilTheBuildFinishes() {
        let activity = PortableBudgetExportActivity()
        activity.shareRequested()
        #expect(activity.isPreparing)
        activity.begin()
        activity.end()
        #expect(!activity.isPreparing)
    }

    @Test func shareTapWithoutAFileRequestClearsAfterTheLimit() async throws {
        let activity = PortableBudgetExportActivity(awaitingLimit: .milliseconds(50))
        activity.shareRequested()
        #expect(activity.isPreparing)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!activity.isPreparing)
    }

    @Test func madeTransferClearsActivityAfterSuccessAndFailure() async throws {
        let (bundle, _) = try await makeBundle()
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let appState = AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: bundle.keychain,
            localFirstStore: bundle.store
        )
        let activity = PortableBudgetExportActivity()

        let transfer = PortableBudgetArchiveTransfer.make(
            budgetID: bundle.budget.syncID, appState: appState, activity: activity
        )
        _ = try await transfer.exportArchive()
        #expect(activity.inFlightCount == 0)

        let refused = PortableBudgetArchiveTransfer.make(
            budgetID: "a-budget-that-is-not-open", appState: appState, activity: activity
        )
        await #expect(throws: (any Error).self) {
            try await refused.exportArchive()
        }
        #expect(activity.inFlightCount == 0)
        appState.clearAppInitiatedSystemUIPresentationSuppression()
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
