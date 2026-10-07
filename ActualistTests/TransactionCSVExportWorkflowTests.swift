import Foundation
import Testing
@testable import Actualist

@Suite @MainActor
struct TransactionCSVExportWorkflowTests {
    private final class ThrowingRepository: TransactionCSVExportRepositoryProtocol {
        func exportTransactionsCSV(_ request: TransactionCSVExportRequest) async throws -> TransactionCSVExport {
            throw CancellationError()
        }
    }

    @Test func cancellationWithCurrentGenerationReturnsToIdle() async {
        let workflow = TransactionCSVExportWorkflow()

        await workflow.export(budgetID: "b", accountID: "a", repository: ThrowingRepository())

        #expect(workflow.state == .idle)
    }
}
