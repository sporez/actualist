import Foundation

extension LocalFirstActualStore {
    // MARK: - Payee mutations

    func createPayeeAndRefresh(budgetID: String, name: String) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let payeeID = UUID().uuidString
        let messages = try await database.createPayeeMessages(
            name: name,
            payeeID: payeeID,
            builder: &builder
        )
        let undo = try await database.payeeUndoMessagesForCreate(payeeID: payeeID, builder: &builder)

        _ = try await database.commitUserAction(
            messages,
            descriptor: .payee(PayeeActionDescriptor(operation: .create, names: [name])),
            source: .ui
        )
        lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func renamePayeeAndRefresh(
        budgetID: String,
        payeeID: String,
        name: String
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.renamePayeeMessages(
            payeeID: payeeID,
            name: name,
            builder: &builder
        )
        guard !messages.isEmpty else {
            return
        }
        let undo = try await database.payeeUndoMessagesForRename(payeeID: payeeID, builder: &builder)

        _ = try await database.commitUserAction(
            messages,
            descriptor: .payee(PayeeActionDescriptor(operation: .rename, names: [name])),
            source: .ui
        )
        lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func mergePayeesAndRefresh(
        budgetID: String,
        sourcePayeeIDs: Set<String>,
        targetPayeeID: String
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        await userActionBeforeCommitHook?()
        // Built inside the write so mapping rows a sync pull added since the
        // review are retargeted too, instead of left pointing at a tombstone.
        let undo = try await database.commitUserActionPlan(source: .ui) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            let messages = try database.mergePayeeMessages(
                in: db,
                sourcePayeeIDs: sourcePayeeIDs,
                targetPayeeID: targetPayeeID,
                builder: &builder
            )
            let undo = try database.payeeUndoMessagesForMerge(
                in: db,
                sourcePayeeIDs: sourcePayeeIDs,
                builder: &builder
            )
            return UserActionPlan(
                drafts: messages,
                descriptor: .payee(PayeeActionDescriptor(operation: .merge, names: [])),
                outcome: undo
            )
        }.outcome
        lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func deletePayeeAndRefresh(budgetID: String, payeeID: String) async throws {
        try await deletePayeesAndRefresh(budgetID: budgetID, payeeIDs: [payeeID])
    }

    func deletePayeesAndRefresh(budgetID: String, payeeIDs: Set<String>) async throws {
        guard !payeeIDs.isEmpty else { return }
        let database = try requireDatabase(for: budgetID)
        await userActionBeforeCommitHook?()
        // The "unused payee" check runs inside the write, so a transaction a
        // sync pull attached to the payee since the review blocks the delete.
        let undo = try await database.commitUserActionPlan(source: .ui) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            var messages: [ActualSyncDecodedMessage] = []
            var undo: [ActualSyncDecodedMessage] = []
            for payeeID in payeeIDs.sorted() {
                messages.append(contentsOf: try database.deletePayeeMessages(
                    in: db,
                    payeeID: payeeID,
                    builder: &builder
                ))
                undo.append(contentsOf: try database.payeeUndoMessagesForDelete(
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
        lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func updatePayeesAndRefresh(
        budgetID: String,
        updates: [PayeeManagementUpdate]
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let mutation = try await database.updatePayeeManagementMessages(
            updates: updates,
            builder: &builder
        )
        guard !mutation.messages.isEmpty else { return }
        _ = try await database.commitUserAction(
            mutation.messages,
            descriptor: .payee(PayeeActionDescriptor(operation: .update, names: [])),
            source: .ui
        )
        lastPayeeUndoMessagesByBudget[budgetID] = mutation.undo
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func setGlobalCategoryLearningAndRefresh(budgetID: String, enabled: Bool) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let mutation = try await database.setGlobalCategoryLearningMessages(
            enabled: enabled,
            builder: &builder
        )
        guard !mutation.messages.isEmpty else { return }
        _ = try await database.commitUserAction(
            mutation.messages,
            descriptor: .learningPref(LearningPrefActionDescriptor(after: enabled)),
            source: .ui
        )
        lastPayeeUndoMessagesByBudget[budgetID] = mutation.undo
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func undoLastPayeeMutationAndRefresh(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        guard let messages = lastPayeeUndoMessagesByBudget[budgetID], !messages.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("there is no payee change to undo")
        }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        lastPayeeUndoMessagesByBudget[budgetID] = nil
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        }
    }

    func reloadAfterPayeeMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        try await publishPayeeManagementSnapshot(database: database, budgetID: budgetID)
        invalidateReports(budgetID: budgetID)

        try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
        await refreshActionLogDiagnosticSnapshot(database: database)
    }

    // MARK: - Account mutations / server operations

    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {
        try await createAccountAndRefresh(
            budgetID: budgetID,
            name: name,
            offbudget: offbudget,
            actionSource: .ui
        )
    }

    func createAccountAndRefresh(
        budgetID: String,
        name: String,
        offbudget: Bool,
        actionSource: BudgetActionSource
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        let accountID = UUID().uuidString
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.createAccountMessages(
            accountID: accountID,
            name: name,
            offbudget: offbudget,
            builder: &builder
        )

        _ = try await database.commitUserAction(
            messages,
            descriptor: .account(AccountActionDescriptor(name: name, offbudget: offbudget)),
            source: actionSource
        )
        try await finishCommittedAccountWrite(database: database, budgetID: budgetID)
    }

    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let mode = try await database.requireBudgetMode(expectedMode)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.categoryCarryoverMessages(
            categoryID: categoryID,
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: Self.categoryCarryoverHorizonMonth(startMonth: startMonth),
            builder: &builder
        )

        _ = try await database.commitUserAction(
            messages,
            descriptor: .carryover(CarryoverActionDescriptor(
                startMonth: startMonth,
                after: carryover,
                categoryCount: 1
            )),
            source: .ui,
            expectedMode: mode
        )
        await didSetCarryover()
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let mode = try await database.requireBudgetMode(expectedMode)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.allExpenseCategoryCarryoverMessages(
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: Self.categoryCarryoverHorizonMonth(startMonth: startMonth),
            builder: &builder
        )

        if !messages.isEmpty {
            _ = try await database.commitUserAction(
                messages,
                descriptor: .carryover(CarryoverActionDescriptor(
                    startMonth: startMonth,
                    after: carryover,
                    categoryCount: 0
                )),
                source: .ui,
                expectedMode: mode
            )
        }
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryHiddenMessages(
            categoryID: categoryID,
            hidden: hidden,
            builder: &builder
        )
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        await didUpdate()
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.setCategoryGroupHiddenMessages(
            groupID: groupID,
            hidden: hidden,
            builder: &builder
        )
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        await didUpdate()
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    // Actual applies carryover through the created budget horizon.
    private static func categoryCarryoverHorizonMonth(
        startMonth: String,
        now: Date = Date()
    ) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let horizonDate = calendar.date(byAdding: .month, value: 12, to: now) ?? now
        return max(startMonth, YearMonth(date: horizonDate).rawValue)
    }

    // BudgetRepositoryProtocol witness; records the gesture with a UI source.
    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await applyBudgetTemplateAndRefresh(reviewRevision: nil,
            expectedMode: expectedMode,
            command: command,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didApply: didApply
        )
    }

    func applyBudgetTemplateAndRefresh(reviewRevision: BudgetTemplateReviewRevision? = nil,
        expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let mode = try await database.requireBudgetMode(expectedMode)
        await userActionBeforeCommitHook?()
        _ = try await database.commitUserActionPlan(
            source: actionSource,
            expectedMode: reviewRevision?.modeIdentity ?? mode,
            expectedTemplateReviewRevision: reviewRevision
        ) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            let result = try database.budgetTemplateApply(
                command: command,
                month: month,
                db: db,
                builder: &builder
            )
            // A goal-only or orphan-cleanup write moved no money; History
            // records money-flow gestures only.
            return UserActionPlan(
                drafts: result.messages,
                descriptor: result.assignments.isEmpty
                    ? nil
                    : .template(month: month, mode: command.mode, assignments: result.assignments),
                outcome: ()
            )
        }
        await didApply()
        try await finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func previewRules(for draft: TransactionDraft, budgetID: String) async throws -> TransactionRulePreview {
        let database = try requireDatabase(for: budgetID)
        return try await database.previewRules(for: draft)
    }

    func repairSplitTransactionsAndRefresh(budgetID: String) async throws -> SplitTransactionRepairResult {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let repair = try await database.repairSplitTransactionsMessages(builder: &builder)
        if !repair.write.messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(repair.write.messages)
        }
        try await finishCommittedTransactionWrite(
            database: database,
            budgetID: budgetID,
            accountIDs: repair.write.affectedAccountIDs
        )
        return repair.result
    }

    func reloadAfterTransactionMutation(
        database: BudgetDatabase,
        budgetID: String,
        accountIDs: [String]
    ) async throws {
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        try await refreshLoadedTransactionFeedCaches(
            database: database,
            budgetID: budgetID,
            accountIDs: Set(accountIDs)
        )
        await refreshActionLogDiagnosticSnapshot(database: database)
    }

    func reloadAfterBudgetMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
        await refreshActionLogDiagnosticSnapshot(database: database)
    }

    func reloadAfterAccountMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        await refreshActionLogDiagnosticSnapshot(database: database)
    }
}
