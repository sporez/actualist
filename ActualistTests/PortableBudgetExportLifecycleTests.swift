import Foundation
import Testing
@testable import Actualist

/// Plaintext export ZIP lifecycle: where it is written, and when it is removed
/// (reset, re-export, sign-out, age).
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

    @Test func resetRemovesTheExportFile() async throws {
        let (bundle, files) = try await makeBundle()
        let workflow = PortableBudgetExportWorkflow(files: files)
        await workflow.export(budgetID: bundle.budget.syncID, store: bundle.store)
        guard case .ready(let url) = workflow.state else {
            Issue.record("export did not finish: \(workflow.state)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))

        workflow.reset()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(workflow.state == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledExportWithCurrentGenerationReturnsToIdleAndLeavesNoArchive() async throws {
        let (bundle, files) = try await makeBundle()
        let workflow = PortableBudgetExportWorkflow(files: files)

        let task = Task { await workflow.export(budgetID: bundle.budget.syncID, store: bundle.store) }
        task.cancel()
        await task.value

        #expect(workflow.state == .idle)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: files.directory.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func secondExportRemovesTheFirst() async throws {
        let (bundle, files) = try await makeBundle()
        let workflow = PortableBudgetExportWorkflow(files: files)
        await workflow.export(budgetID: bundle.budget.syncID, store: bundle.store)
        guard case .ready(let first) = workflow.state else {
            Issue.record("first export did not finish")
            return
        }

        await workflow.export(budgetID: bundle.budget.syncID, store: bundle.store)

        guard case .ready(let second) = workflow.state else {
            Issue.record("second export did not finish")
            return
        }
        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
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

        try bundle.store.eraseLocalData()

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
        let plain = PortableBudgetExportWorkflow.footerText(isBudgetEncrypted: false)
        let encrypted = PortableBudgetExportWorkflow.footerText(isBudgetEncrypted: true)

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
