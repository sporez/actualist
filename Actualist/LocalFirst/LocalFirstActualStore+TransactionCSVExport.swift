import Foundation

extension LocalFirstActualStore: TransactionCSVExportRepositoryProtocol {
    func exportTransactionsCSV(_ request: TransactionCSVExportRequest) async throws -> TransactionCSVExport {
        try Task.checkCancellation()
        let database = try requireDatabase(for: request.budgetID)
        let sessionID = transactionFeedRequestIdentity.sessionID
        let rows = try await database.fetchTransactionCSVExportRows(
            accountID: request.accountID,
            query: request.query
        )
        try Task.checkCancellation()
        guard transactionFeedRequestIdentity.sessionID == sessionID,
              self.database === database,
              openedBudgetID == request.budgetID else {
            throw CancellationError()
        }
        return TransactionCSVEncoder().encode(rows)
    }
}
