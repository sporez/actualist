import Foundation
import Testing
@testable import Actualist

/// Import size caps (plan decision D6c): 10 MB and 50,000 rows. The pipeline
/// entry points take the caps as parameters, so the boundary is exercised with
/// a few bytes rather than a 10 MB file.
@MainActor
struct TransactionCSVImportLimitsTests {
    private func writeFile(byteCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "csv-limits-\(UUID().uuidString).csv")
        try Data(repeating: UInt8(ascii: "a"), count: byteCount).write(to: url)
        return url
    }

    private func csv(rows: Int) -> Data {
        var text = "Date,Payee,Amount\n"
        for index in 0..<rows {
            text += "2026-09-27,Payee \(index),-1.00\n"
        }
        return Data(text.utf8)
    }

    @Test func capsMatchTheDecision() {
        #expect(TransactionCSVImportLimits.maxFileBytes == 10 * 1_024 * 1_024)
        #expect(TransactionCSVImportLimits.maxRows == 50_000)
    }

    @Test func fileExactlyAtTheByteCapIsRead() async throws {
        let data = try await TransactionCSVImportPipeline.readFile(
            at: try writeFile(byteCount: 10),
            maxBytes: 10
        )
        #expect(data.count == 10)
    }

    @Test func fileOneByteOverTheCapThrowsFileTooLarge() async throws {
        let url = try writeFile(byteCount: 11)
        await #expect(throws: TransactionCSVImportError.fileTooLarge) {
            _ = try await TransactionCSVImportPipeline.readFile(at: url, maxBytes: 10)
        }
    }

    @Test func parseRejectsDataOverTheByteCap() async {
        await #expect(throws: TransactionCSVImportError.fileTooLarge) {
            _ = try await TransactionCSVImportPipeline.rows(
                from: Data(count: 11),
                options: TransactionCSVImportOptions(),
                maxBytes: 10
            )
        }
    }

    @Test func rowCountAtTheCapMapsAndOneOverThrows() async throws {
        let atCap = try await TransactionCSVImportPipeline.rows(
            from: csv(rows: 3),
            options: TransactionCSVImportOptions(),
            maxRows: 3
        )
        #expect(atCap.count == 3)
        await #expect(throws: TransactionCSVImportError.tooManyRows) {
            _ = try await TransactionCSVImportPipeline.rows(
                from: csv(rows: 4),
                options: TransactionCSVImportOptions(),
                maxRows: 3
            )
        }
    }

    @Test func rowCapIsEnforcedBeforeAnyRowIsMapped() async {
        // The last row is invalid; the cap error must win over the row error.
        let data = Data("Date,Payee,Amount\n2026-09-27,A,-1.00\n2026-09-27,B,-1.00\nnot-a-date,C,-1.00\n".utf8)
        await #expect(throws: TransactionCSVImportError.tooManyRows) {
            _ = try await TransactionCSVImportPipeline.rows(
                from: data,
                options: TransactionCSVImportOptions(),
                maxRows: 2
            )
        }
    }

    @Test func oversizedFileFailsTheCoordinatorWithoutCallingPrepare() async throws {
        let repository = FakeTransactionCSVImportRepository()
        let coordinator = TransactionCSVImportCoordinator(maxFileBytes: 10)
        await coordinator.load(
            contentsOf: try writeFile(byteCount: 11),
            accountID: "checking",
            budgetID: "group-1",
            repository: repository
        )
        #expect(repository.prepareCallCount == 0)
        #expect(coordinator.failureMessage == TransactionCSVImportError.fileTooLarge.message)
    }

    @Test func fileAtTheCapReachesPrepare() async throws {
        let repository = FakeTransactionCSVImportRepository()
        let coordinator = TransactionCSVImportCoordinator(maxFileBytes: 10)
        await coordinator.load(
            contentsOf: try writeFile(byteCount: 10),
            accountID: "checking",
            budgetID: "group-1",
            repository: repository
        )
        #expect(repository.prepareCallCount == 1)
        #expect(coordinator.summary?.insert == 1)
    }
}
