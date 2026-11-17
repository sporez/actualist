import Foundation

/// Entity notes (category, category group, account and budget-month notes)
/// on the store: the note read and its write with the reload that follows.
/// The store owns it.
@MainActor
final class EntityNoteWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func entityNote(
        target: ActualNoteTarget,
        budgetID: String
    ) async throws -> ActualNoteBody {
        try await EntityNoteSQL.fetchEntityNote(
            target: target,
            in: store.requireDatabase(for: budgetID)
        )
    }

    func setEntityNoteAndRefresh(
        target: ActualNoteTarget,
        userBody: String,
        budgetID: String
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
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
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
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
            try await store.reloadAccountCaches(database: database, budgetID: budgetID)
        case .budgetMonth:
            _ = try await store.budgetMonth(budgetID: budgetID, selectedMonth: target.entityID)
        case .category, .categoryGroup:
            guard let selectedMonth = store.loadedBudgetMonthsByBudget[budgetID]?.selectedMonth else {
                return
            }
            _ = try await store.budgetMonth(budgetID: budgetID, selectedMonth: selectedMonth)
        }
    }
}

extension EntityNoteWorkflows: EntityNotesRepositoryProtocol { }
