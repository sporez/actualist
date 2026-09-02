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

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
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

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func mergePayeesAndRefresh(
        budgetID: String,
        sourcePayeeIDs: Set<String>,
        targetPayeeID: String
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.mergePayeeMessages(
            sourcePayeeIDs: sourcePayeeIDs,
            targetPayeeID: targetPayeeID,
            builder: &builder
        )
        let undo = try await database.payeeUndoMessagesForMerge(
            sourcePayeeIDs: sourcePayeeIDs,
            builder: &builder
        )

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func deletePayeeAndRefresh(budgetID: String, payeeID: String) async throws {
        try await deletePayeesAndRefresh(budgetID: budgetID, payeeIDs: [payeeID])
    }

    func deletePayeesAndRefresh(budgetID: String, payeeIDs: Set<String>) async throws {
        guard !payeeIDs.isEmpty else { return }
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        var messages: [ActualSyncDecodedMessage] = []
        var undo: [ActualSyncDecodedMessage] = []
        for payeeID in payeeIDs.sorted() {
            messages.append(contentsOf: try await database.deletePayeeMessages(
                payeeID: payeeID,
                builder: &builder
            ))
            undo.append(contentsOf: try await database.payeeUndoMessagesForDelete(
                payeeID: payeeID,
                builder: &builder
            ))
        }

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        lastPayeeUndoMessagesByBudget[budgetID] = undo
        try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
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
        _ = try await database.commitLocalSyncMessagesAndEnqueue(mutation.messages)
        lastPayeeUndoMessagesByBudget[budgetID] = mutation.undo
        try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func setGlobalCategoryLearningAndRefresh(budgetID: String, enabled: Bool) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let mutation = try await database.setGlobalCategoryLearningMessages(
            enabled: enabled,
            builder: &builder
        )
        guard !mutation.messages.isEmpty else { return }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(mutation.messages)
        lastPayeeUndoMessagesByBudget[budgetID] = mutation.undo
        try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func undoLastPayeeMutationAndRefresh(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        guard let messages = lastPayeeUndoMessagesByBudget[budgetID], !messages.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("there is no payee change to undo")
        }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        lastPayeeUndoMessagesByBudget[budgetID] = nil
        try await reloadAfterPayeeMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func reloadAfterPayeeMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        payeesByBudget[budgetID] = try await database.fetchPayeeManagementSnapshot()
            .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
        invalidateReports(budgetID: budgetID)

        let prefix = "\(budgetID)|"
        for (key, page) in Array(accountTransactionsByKey) where key.hasPrefix(prefix) {
            let accountID = String(key.dropFirst(prefix.count))
            accountTransactionsByKey[key] = TransactionFeedPage(
                loaded: try await loadedAccountTransactions(
                    database: database,
                    budgetID: budgetID,
                    accountID: accountID,
                    query: nil,
                    limit: max(page.nextOffset, transactionPageSize),
                    offset: 0
                )
            )
        }
        if let currentSpending = spendingTransactionsByBudget[budgetID] {
            spendingTransactionsByBudget[budgetID] = TransactionFeedPage(
                loaded: try await loadedSpendingTransactions(
                    database: database,
                    budgetID: budgetID,
                    query: nil,
                    limit: max(currentSpending.nextOffset, transactionPageSize),
                    offset: 0
                )
            )
        }
        categoryTransactionsByKey = categoryTransactionsByKey.filter { !$0.key.hasPrefix(prefix) }
        uncategorizedTransactionsByKey = uncategorizedTransactionsByKey.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Account mutations / server operations

    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {
        let database = try requireDatabase(for: budgetID)
        let accountID = UUID().uuidString
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.createAccountMessages(
            accountID: accountID,
            name: name,
            offbudget: offbudget,
            builder: &builder
        )

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        try await reloadAfterAccountMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func reconcileAccountAndRefresh(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> AccountReconciliationResult {
        throw LocalFirstError.unsupportedWrite
    }

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.categoryCarryoverMessages(
            categoryID: categoryID,
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: Self.categoryCarryoverHorizonMonth(startMonth: startMonth),
            builder: &builder
        )

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        await didSetCarryover()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    func setAllExpenseCategoryCarryoverAndRefresh(
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.allExpenseCategoryCarryoverMessages(
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: Self.categoryCarryoverHorizonMonth(startMonth: startMonth),
            builder: &builder
        )

        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
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
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
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
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
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
    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await applyBudgetTemplateAndRefresh(
            command: command,
            budgetID: budgetID,
            month: month,
            actionSource: .ui,
            didApply: didApply
        )
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let result = try await database.budgetTemplateApply(
            command: command,
            month: month,
            builder: &builder
        )

        if result.assignments.isEmpty {
            // A goal-only or orphan-cleanup write moved no money; History
            // records money-flow gestures only.
            _ = try await database.commitLocalSyncMessagesAndEnqueue(result.messages)
        } else {
            _ = try await database.commitUserAction(
                result.messages,
                descriptor: .template(month: month, mode: command.mode, assignments: result.assignments),
                source: actionSource
            )
        }
        await didApply()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
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
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: repair.write.affectedAccountIDs,
            monthIDs: []
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return repair.result
    }

    func reloadAfterTransactionMutation(
        database: BudgetDatabase,
        budgetID: String,
        accountIDs: [String],
        monthIDs: [String]
    ) async throws {
        invalidateReports(budgetID: budgetID)
        monthsByBudget[budgetID] = nil
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        if let currentSpending = spendingTransactionsByBudget[budgetID] {
            let limit = max(currentSpending.nextOffset, transactionPageSize)
            spendingTransactionsByBudget[budgetID] = TransactionFeedPage(
                loaded: try await loadedSpendingTransactions(
                    database: database,
                    budgetID: budgetID,
                    query: nil,
                    limit: limit,
                    offset: 0
                )
            )
        }
        for accountID in Set(accountIDs) {
            let key = transactionKey(budgetID, accountID)
            let limit = max(accountTransactionsByKey[key]?.nextOffset ?? transactionPageSize, transactionPageSize)
            accountTransactionsByKey[key] = TransactionFeedPage(
                loaded: try await loadedAccountTransactions(
                    database: database,
                    budgetID: budgetID,
                    accountID: accountID,
                    query: nil,
                    limit: limit,
                    offset: 0
                )
            )
        }
    }

    func reloadAfterBudgetMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        invalidateReports(budgetID: budgetID)
        monthsByBudget[budgetID] = nil
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        if let currentSpending = spendingTransactionsByBudget[budgetID] {
            let limit = max(currentSpending.nextOffset, transactionPageSize)
            spendingTransactionsByBudget[budgetID] = TransactionFeedPage(
                loaded: try await loadedSpendingTransactions(
                    database: database,
                    budgetID: budgetID,
                    query: nil,
                    limit: limit,
                    offset: 0
                )
            )
        }
    }

    func reloadAfterAccountMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
    }
}
