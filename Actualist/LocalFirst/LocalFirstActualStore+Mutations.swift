import Foundation

extension LocalFirstActualStore {
    // MARK: - Account mutations / server operations

    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let accountID = UUID().uuidString
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try await database.createAccountMessages(
            accountID: accountID,
            name: name,
            offbudget: offbudget,
            builder: &builder
        )

        _ = try await database.applyLocalSyncMessagesAndEnqueue(messages, baseTimestamp: latestTimestamp)
        try await reloadAfterAccountMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func reconcileAccountAndRefresh(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> APIAccountReconciliationResult {
        throw LocalFirstError.unsupportedWrite
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try await database.assignCategoryBudgetMessages(
            categoryID: categoryID,
            budgeted: budgeted,
            month: month,
            builder: &builder
        )

        _ = try await database.applyLocalSyncMessagesAndEnqueue(messages, baseTimestamp: latestTimestamp)
        await didAssign()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try await database.categoryCarryoverMessages(
            categoryID: categoryID,
            carryover: carryover,
            startMonth: startMonth,
            throughMonth: Self.categoryCarryoverHorizonMonth(startMonth: startMonth),
            builder: &builder
        )

        _ = try await database.applyLocalSyncMessagesAndEnqueue(messages, baseTimestamp: latestTimestamp)
        await didSetCarryover()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: startMonth)
    }

    /// Actual creates budget sheets through one year beyond the current month. Its native
    /// carryover action writes from the selected month through that created horizon.
    private static func categoryCarryoverHorizonMonth(
        startMonth: String,
        now: Date = Date()
    ) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let horizonDate = calendar.date(byAdding: .month, value: 12, to: now) ?? now
        return max(startMonth, YearMonth(date: horizonDate).rawValue)
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try await database.budgetTemplateMessages(
            command: command,
            month: month,
            builder: &builder
        )

        _ = try await database.applyLocalSyncMessagesAndEnqueue(messages, baseTimestamp: latestTimestamp)
        await didApply()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(
            commands: [command],
            budgetID: budgetID,
            month: month,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try await database.moveMoneyMessages(
            commands: commands,
            month: month,
            builder: &builder
        )

        _ = try await database.applyLocalSyncMessagesAndEnqueue(messages, baseTimestamp: latestTimestamp)
        await didMove()
        try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func previewRules(for draft: TransactionDraft, budgetID: String) async throws -> TransactionRulePreview {
        throw LocalFirstError.unsupportedWrite
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }
        let database = try requireDatabase(for: budgetID)
        let transactionID = UUID().uuidString
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let payeeResolution = try await database.resolveOrCreatePayeeMessages(
            selectedPayeeID: draft.payeeID,
            payeeName: draft.payeeName,
            builder: &builder
        )

        let transactionMessages: [ActualSyncDecodedMessage]
        var changedAccounts = [draft.accountID]
        if draft.isTransfer {
            let transfer = try await database.createTransferTransactionMessages(
                draft: draft,
                sourceTransactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder
            )
            transactionMessages = transfer.messages
            changedAccounts.append(transfer.destinationAccountID)
        } else if draft.isSplit {
            transactionMessages = try await database.createSplitTransactionMessages(
                draft: draft,
                parentTransactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder
            )
        } else {
            transactionMessages = try await database.createSimpleTransactionMessages(
                draft,
                transactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder
            )
        }

        let messages = payeeResolution.messages + transactionMessages
        _ = try await database.applyLocalSyncMessagesAndEnqueue(messages, baseTimestamp: latestTimestamp)
        await didCreate()

        let uniqueAccounts = Array(Set(changedAccounts))
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: uniqueAccounts,
            monthIDs: [draft.month.rawValue]
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: uniqueAccounts,
                months: [draft.month.rawValue],
                transactions: [transactionID]
            )
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }

        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let payeeResolution = try await database.resolveOrCreatePayeeMessages(
            selectedPayeeID: draft.payeeID,
            payeeName: draft.payeeName,
            builder: &builder
        )
        let update = try await database.updateTransactionMessages(
            transactionID: transactionID,
            draft: draft,
            payeeID: payeeResolution.payeeID,
            builder: &builder
        )

        let messages = payeeResolution.messages + update.messages
        _ = try await database.applyLocalSyncMessagesAndEnqueue(messages, baseTimestamp: latestTimestamp)
        await didUpdate()

        let changedAccounts = Array(Set(update.affectedAccountIDs + [originalAccountID, draft.accountID]))
        let changedMonths = Array(Set([originalMonth, draft.month.rawValue]))
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: changedAccounts,
            monthIDs: changedMonths
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: changedMonths,
                transactions: update.affectedTransactionIDs
            )
        )
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let transactionID = transaction.id, !transactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard let monthID = transaction.date.actualYearMonth else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }

        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let messages = try await database.categorizeTransactionMessages(
            transactionID: transactionID,
            categoryID: categoryID,
            builder: &builder
        )

        _ = try await database.applyLocalSyncMessagesAndEnqueue(messages, baseTimestamp: latestTimestamp)
        await didUpdate()
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: [transaction.account],
            monthIDs: [monthID]
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [transaction.account],
                months: [monthID],
                transactions: [transactionID]
            )
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let transactionID = transaction.id, !transactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard let monthID = transaction.date.actualYearMonth else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }
        guard let nodeID = openedNodeID else {
            throw LocalFirstError.budgetNotOpened
        }

        let database = try requireDatabase(for: budgetID)
        let latestTimestamp = try await database.latestSyncTimestamp()
        var builder = LocalFirstSyncMessageBuilder(
            nodeID: nodeID,
            latestTimestamp: latestTimestamp
        )
        let delete = try await database.deleteTransactionMessages(
            transactionID: transactionID,
            builder: &builder
        )

        _ = try await database.applyLocalSyncMessagesAndEnqueue(delete.messages, baseTimestamp: latestTimestamp)
        await didDelete()

        let changedAccounts = Array(Set(delete.affectedAccountIDs + [transaction.account]))
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: changedAccounts,
            monthIDs: [monthID]
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: [monthID],
                transactions: delete.affectedTransactionIDs
            )
        )
    }

    func reloadAfterTransactionMutation(
        database: BudgetDatabase,
        budgetID: String,
        accountIDs: [String],
        monthIDs: [String]
    ) async throws {
        invalidateReports(budgetID: budgetID)
        monthsByBudget[budgetID] = nil
        accountsByBudget[budgetID] = try await database.fetchAccountDisplays()
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
        accountsByBudget[budgetID] = try await database.fetchAccountDisplays()
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
        accountsByBudget[budgetID] = try await database.fetchAccountDisplays()
    }

}
