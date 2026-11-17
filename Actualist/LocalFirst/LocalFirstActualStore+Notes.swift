import Foundation

extension LocalFirstActualStore {
    func entityNote(
        target: ActualNoteTarget,
        budgetID: String
    ) async throws -> ActualNoteBody {
        try await EntityNoteSQL.fetchEntityNote(
            target: target,
            in: requireDatabase(for: budgetID)
        )
    }

    func setEntityNoteAndRefresh(
        target: ActualNoteTarget,
        userBody: String,
        budgetID: String
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await EntityNoteSQL.setEntityNoteMessages(
            target: target,
            userBody: userBody,
            builder: &builder,
            in: database
        )
        guard !messages.isEmpty else {
            return
        }

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterEntityNoteMutation(
                target: target,
                database: database,
                budgetID: budgetID
            )
        }
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
