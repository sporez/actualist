import Foundation

extension LocalFirstActualStore {
    func accountReconciliationSnapshot(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationSnapshot {
        try await requireDatabase(for: budgetID)
            .accountReconciliationSnapshot(accountID: accountID)
    }
}
