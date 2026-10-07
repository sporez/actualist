import Foundation
import Observation

@MainActor
@Observable
final class TransactionCSVExportWorkflow {
    enum State: Equatable {
        case idle
        case exporting
        case ready(TransactionCSVExport)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var generation = 0

    func export(
        budgetID: String,
        accountID: String,
        repository: any TransactionCSVExportRepositoryProtocol
    ) async {
        generation &+= 1
        let requestGeneration = generation
        state = .exporting
        do {
            let result = try await repository.exportTransactionsCSV(
                TransactionCSVExportRequest(
                    budgetID: budgetID,
                    accountID: accountID,
                    query: TransactionFeedQuery()
                )
            )
            guard requestGeneration == generation else { return }
            // A cancelled task must not strand `.exporting`.
            state = Task.isCancelled ? .idle : .ready(result)
        } catch {
            guard requestGeneration == generation else { return }
            guard !Task.isCancelled, !error.isCancellation else {
                state = .idle
                return
            }
            state = .failed("The CSV could not be prepared. Your budget has not been changed.")
        }
    }

    func cancel() {
        generation &+= 1
        state = .idle
    }
}
