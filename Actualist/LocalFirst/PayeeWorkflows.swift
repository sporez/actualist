import Foundation

/// Payees screen and Shortcuts payee access on the store: the payee
/// management snapshot, its writes and the undo of the last write. The store
/// owns it; the snapshot cache and the undo messages stay on the store,
/// which clears them on `closeOpenBudget`.
@MainActor
final class PayeeWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func cachedPayeeManagementSnapshot(budgetID: String) -> PayeeManagementSnapshot? {
        store.payeesByBudget[budgetID]
    }

    func refreshPayeeManagementSnapshot(budgetID: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        try await publishPayeeManagementSnapshot(database: database, budgetID: budgetID)
    }

    /// Reads the payee snapshot and publishes it only while the session that
    /// asked is still open, so a reload that outlives `closeOpenBudget` cannot
    /// repopulate cleared caches. The one publisher for the attached tails and
    /// the standalone refresh.
    func publishPayeeManagementSnapshot(database: BudgetDatabase, budgetID: String) async throws {
        let generation = store.budgetSessionGeneration
        let snapshot = try await PayeeManagementSQL.fetchPayeeManagementSnapshot(in: database)
            .settingCanUndo(store.lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
        #if DEBUG
        await store.testSeams?.payeeSnapshotReadHook?(budgetID)
        #endif
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        store.payeesByBudget[budgetID] = snapshot
    }

    func createPayeeAndRefresh(budgetID: String, name: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let payeeID = UUID().uuidString
        let messages = try await PayeeManagementSQL.createPayeeMessages(
            name: name,
            payeeID: payeeID,
            builder: &builder,
            in: database
        )
        let undo = try PayeeManagementSQL.payeeUndoMessagesForCreate(payeeID: payeeID, builder: &builder)

        _ = try await database.commitUserAction(
            messages,
            descriptor: .payee(PayeeActionDescriptor(operation: .create, names: [name])),
            source: .ui
        )
        store.lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func renamePayeeAndRefresh(
        budgetID: String,
        payeeID: String,
        name: String
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await PayeeManagementSQL.renamePayeeMessages(
            payeeID: payeeID,
            name: name,
            builder: &builder,
            in: database
        )
        guard !messages.isEmpty else {
            return
        }
        let undo = try await PayeeManagementSQL.payeeUndoMessagesForRename(payeeID: payeeID, builder: &builder, in: database)

        _ = try await database.commitUserAction(
            messages,
            descriptor: .payee(PayeeActionDescriptor(operation: .rename, names: [name])),
            source: .ui
        )
        store.lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func mergePayeesAndRefresh(
        budgetID: String,
        sourcePayeeIDs: Set<String>,
        targetPayeeID: String
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
        #if DEBUG
        await store.testSeams?.userActionBeforeCommitHook?()
        #endif
        // Built inside the write so mapping rows a sync pull added since the
        // review are retargeted too, instead of left pointing at a tombstone.
        let undo = try await database.commitUserActionPlan(source: .ui) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            let messages = try PayeeManagementSQL.mergePayeeMessages(
                sourcePayeeIDs: sourcePayeeIDs,
                targetPayeeID: targetPayeeID,
                builder: &builder,
                in: database,
                db: db
            )
            let undo = try PayeeManagementSQL.payeeUndoMessagesForMerge(
                sourcePayeeIDs: sourcePayeeIDs,
                builder: &builder,
                in: database,
                db: db
            )
            return UserActionPlan(
                drafts: messages,
                descriptor: .payee(PayeeActionDescriptor(operation: .merge, names: [])),
                outcome: undo
            )
        }.outcome
        store.lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func deletePayeeAndRefresh(budgetID: String, payeeID: String) async throws {
        try await deletePayeesAndRefresh(budgetID: budgetID, payeeIDs: [payeeID])
    }

    func deletePayeesAndRefresh(budgetID: String, payeeIDs: Set<String>) async throws {
        guard !payeeIDs.isEmpty else { return }
        let database = try store.requireDatabase(for: budgetID)
        #if DEBUG
        await store.testSeams?.userActionBeforeCommitHook?()
        #endif
        // The "unused payee" check runs inside the write, so a transaction a
        // sync pull attached to the payee since the review blocks the delete.
        let undo = try await database.commitUserActionPlan(source: .ui) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            var messages: [ActualSyncDecodedMessage] = []
            var undo: [ActualSyncDecodedMessage] = []
            for payeeID in payeeIDs.sorted() {
                messages.append(contentsOf: try PayeeManagementSQL.deletePayeeMessages(
                    payeeID: payeeID,
                    builder: &builder,
                    in: database,
                    db: db
                ))
                undo.append(contentsOf: try PayeeManagementSQL.payeeUndoMessagesForDelete(
                    payeeID: payeeID,
                    builder: &builder
                ))
            }
            return UserActionPlan(
                drafts: messages,
                descriptor: .payee(PayeeActionDescriptor(operation: .delete, names: [])),
                outcome: undo
            )
        }.outcome
        store.lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func updatePayeesAndRefresh(
        budgetID: String,
        updates: [PayeeManagementUpdate]
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let mutation = try await PayeeManagementSQL.updatePayeeManagementMessages(
            updates: updates,
            builder: &builder,
            in: database
        )
        guard !mutation.messages.isEmpty else { return }
        _ = try await database.commitUserAction(
            mutation.messages,
            descriptor: .payee(PayeeActionDescriptor(operation: .update, names: [])),
            source: .ui
        )
        store.lastPayeeUndoMessagesByBudget[budgetID] = mutation.undo
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func setGlobalCategoryLearningAndRefresh(budgetID: String, enabled: Bool) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let mutation = try await PayeeManagementSQL.setGlobalCategoryLearningMessages(
            enabled: enabled,
            builder: &builder,
            in: database
        )
        guard !mutation.messages.isEmpty else { return }
        _ = try await database.commitUserAction(
            mutation.messages,
            descriptor: .learningPref(LearningPrefActionDescriptor(after: enabled)),
            source: .ui
        )
        store.lastPayeeUndoMessagesByBudget[budgetID] = mutation.undo
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func undoLastPayeeMutationAndRefresh(budgetID: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        guard let messages = store.lastPayeeUndoMessagesByBudget[budgetID], !messages.isEmpty else {
            throw LocalFirstError.refusedChange("There is no payee change to undo.")
        }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        store.lastPayeeUndoMessagesByBudget[budgetID] = nil
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func reloadAfterPayeeMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        try await store.reloadSelectedBudgetCache(budgetID: budgetID)
        try await publishPayeeManagementSnapshot(database: database, budgetID: budgetID)
        store.reports.invalidateReports(budgetID: budgetID)

        try await store.transactions.refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
        await store.history.refreshActionLogDiagnosticSnapshot(database: database)
    }
}

extension PayeeWorkflows: PayeeRepositoryProtocol { }
