import Foundation
import Testing
@testable import Actualist

@MainActor
final class FakeTransactionCSVImportRepository: TransactionCSVImportRepositoryProtocol {
    private(set) var prepareCallCount = 0
    private(set) var applyRequests: [TransactionCSVImportApplyRequest] = []
    var applyError: (any Error)?
    var dispositions: [TransactionCSVImportDisposition] = [.insert(isTransfer: false)]

    func prepareTransactionCSVImport(
        _ request: TransactionCSVImportPreparationRequest
    ) async throws -> TransactionCSVImportReview {
        prepareCallCount += 1
        let date = TransactionCSVImportMapper.dayDate(fromISO: "2026-09-27")!
        let rows = dispositions.enumerated().map { index, disposition in
            TransactionCSVImportReviewRow(
                row: TransactionCSVImportRow(
                    id: "csv-row-\(index + 1)",
                    sourceLine: index + 1,
                    dateText: "2026-09-27",
                    date: date,
                    amountMinorUnits: -100,
                    payeeName: "Sample Market",
                    notes: nil,
                    categoryName: nil,
                    cleared: nil,
                    importedID: nil
                ),
                disposition: disposition
            )
        }
        return TransactionCSVImportReview(rows: rows, sessionGeneration: 7)
    }

    func applyTransactionCSVImport(
        _ request: TransactionCSVImportApplyRequest
    ) async throws -> TransactionCSVImportApplyResult {
        applyRequests.append(request)
        if let applyError { throw applyError }
        return TransactionCSVImportApplyResult(insertedCount: 1, updatedCount: 0)
    }
}

@MainActor
struct TransactionCSVImportCoordinatorTests {
    private func writeCSV(_ text: String = "Date,Payee,Amount\n2026-09-27,Sample Market,-1.00\n") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "csv-coordinator-\(UUID().uuidString).csv")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func reviewSummaryCountsReconciledSkipsSeparatelyFromDuplicates() async throws {
        let repository = FakeTransactionCSVImportRepository()
        repository.dispositions = [.insert(isTransfer: false), .ignored, .skippedReconciled]
        let coordinator = TransactionCSVImportCoordinator()
        await coordinator.load(
            contentsOf: try writeCSV(),
            accountID: "checking",
            budgetID: "group-1",
            repository: repository
        )
        let counts = Dictionary(uniqueKeysWithValues: coordinator.summaryLines.map { ($0.title, $0.count) })
        #expect(counts["New rows"] == 1)
        #expect(counts["Duplicates left unchanged"] == 1)
        #expect(counts["Matches reconciled rows"] == 1)
    }

    @Test func onImportedRunsOnceAfterACommittedImport() async throws {
        let repository = FakeTransactionCSVImportRepository()
        let coordinator = TransactionCSVImportCoordinator()
        await coordinator.load(
            contentsOf: try writeCSV(),
            accountID: "checking",
            budgetID: "group-1",
            repository: repository
        )
        var importedCount = 0
        await coordinator.submit(repository: repository, onImported: { importedCount += 1 })
        #expect(importedCount == 1)
        #expect(coordinator.state == .completed(TransactionCSVImportApplyResult(insertedCount: 1, updatedCount: 0)))
        // The apply request carries the review's session generation.
        #expect(repository.applyRequests.map(\.sessionGeneration) == [7])
    }

    @Test func onImportedDoesNotRunWhenTheImportFails() async throws {
        let repository = FakeTransactionCSVImportRepository()
        repository.applyError = TransactionCSVImportError.matchChanged(line: 1)
        let coordinator = TransactionCSVImportCoordinator()
        await coordinator.load(
            contentsOf: try writeCSV(),
            accountID: "checking",
            budgetID: "group-1",
            repository: repository
        )
        var importedCount = 0
        await coordinator.submit(repository: repository, onImported: { importedCount += 1 })
        #expect(importedCount == 0)
        #expect(coordinator.failureMessage?.contains("Nothing was imported") == true)
    }

    @Test func reviewStatesThatImportCannotBeUndone() async throws {
        let repository = FakeTransactionCSVImportRepository()
        let coordinator = TransactionCSVImportCoordinator()
        #expect(coordinator.reviewNotice == nil)
        await coordinator.load(
            contentsOf: try writeCSV(),
            accountID: "checking",
            budgetID: "group-1",
            repository: repository
        )
        #expect(coordinator.reviewNotice == "Imported transactions can't be undone.")
        await coordinator.submit(repository: repository)
        #expect(coordinator.reviewNotice == nil)
    }
}
