import Foundation

extension LocalFirstActualStore {
    func entityNote(
        target: ActualNoteTarget,
        budgetID: String
    ) async throws -> ActualNoteBody {
        try await requireDatabase(for: budgetID).fetchEntityNote(target: target)
    }

    func setEntityNoteAndRefresh(
        target: ActualNoteTarget,
        userBody: String,
        budgetID: String
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setEntityNoteMessages(
            target: target,
            userBody: userBody,
            builder: &builder
        )
        guard !messages.isEmpty else {
            return
        }

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        try await reloadAfterEntityNoteMutation(
            target: target,
            database: database,
            budgetID: budgetID
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    private func reloadAfterEntityNoteMutation(
        target: ActualNoteTarget,
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        switch target.kind {
        case .account:
            try await reloadAccountCaches(database: database, budgetID: budgetID)
        case .budgetMonth:
            _ = try await budgetMonth(budgetID: budgetID, selectedMonth: target.entityID)
        case .category, .categoryGroup:
            guard let selectedMonth = loadedBudgetMonthsByBudget[budgetID]?.selectedMonth else {
                return
            }
            _ = try await budgetMonth(budgetID: budgetID, selectedMonth: selectedMonth)
        }
    }
}
