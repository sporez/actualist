import Foundation

extension LocalFirstActualStore {
    func budgets() async throws -> [ActualBudget] {
        cachedBudgets
    }

    func cachedBudgetMonth(budgetID: String) -> LoadedBudgetMonth? {
        loadedBudgetMonthsByBudget[budgetID]
    }

    func budgetCurrency(budgetID: String) -> BudgetCurrency {
        currencyByBudget[budgetID] ?? .usd
    }

    func reloadBudgetCurrency(database: BudgetDatabase, budgetID: String) async {
        currencyByBudget[budgetID] = (try? await database.fetchBudgetCurrency()) ?? .usd
    }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        let months = try await availableMonths(budgetID: budgetID)
        let selected = months.contains(preferredMonth) ? preferredMonth : (months.last ?? preferredMonth)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: selected)
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        let months = try await availableMonths(budgetID: budgetID)
        let monthID = selectedMonth
        let month = try await database.fetchBudgetMonth(month: monthID)
        await reloadBudgetCurrency(database: database, budgetID: budgetID)
        let isTracking = (try? await database.isTrackingBudget()) ?? false
        let loaded = LoadedBudgetMonth(
            availableMonths: months,
            selectedMonth: monthID,
            month: month,
            alerts: try await nativeBudgetAlerts(
                database: database,
                budgetID: budgetID,
                month: month,
                monthID: monthID,
                isTrackingBudget: isTracking
            ),
            currency: budgetCurrency(budgetID: budgetID),
            isTrackingBudget: isTracking
        )
        loadedBudgetMonthsByBudget[budgetID] = loaded
        return loaded
    }

    func accountDisplays(budgetID: String) -> [AccountDisplay] {
        accountsByBudget[budgetID] ?? []
    }

    func accountGroups(budgetID: String) -> [ActualAccountGroup] {
        accountGroupsByBudget[budgetID] ?? []
    }

    func refreshAccountsWithBalances(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
    }

    func reloadAccountCaches(database: BudgetDatabase, budgetID: String) async throws {
        accountsByBudget[budgetID] = try await database.fetchAccountDisplays()
        accountGroupsByBudget[budgetID] = try await database.fetchAccountGroups()
        accountGroupManagementEnabledByBudget[budgetID] = try await database.accountGroupManagementEnabled()
    }

    func cachedPayeeManagementSnapshot(budgetID: String) -> PayeeManagementSnapshot? {
        payeesByBudget[budgetID]
    }

    func refreshPayeeManagementSnapshot(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        payeesByBudget[budgetID] = try await database.fetchPayeeManagementSnapshot()
            .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
    }

    func fetchTransaction(budgetID: String, id: String) async throws -> ActualTransaction? {
        let database = try requireDatabase(for: budgetID)
        return try await database.fetchTransaction(id: id)
    }

    func cachedAccountTransactions(budgetID: String, accountID: String) -> LoadedAccountTransactions? {
        accountTransactionsByKey[transactionKey(budgetID, accountID)]?.loaded
    }

    func cachedSpendingTransactions(budgetID: String) -> LoadedAccountTransactions? {
        spendingTransactionsByBudget[budgetID]?.loaded
    }

    func cachedCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) -> LoadedAccountTransactions? {
        categoryTransactionsByKey[categoryTransactionKey(budgetID, categoryID, month)]?.loaded
    }

    func cachedUncategorizedTransactions(
        budgetID: String,
        month: String
    ) -> LoadedUncategorizedTransactions? {
        uncategorizedTransactionsByKey[uncategorizedTransactionKey(budgetID, month)]
    }

    func refreshAccountTransactions(budgetID: String, accountID: String) async throws {
        let database = try requireDatabase(for: budgetID)
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

    func refreshSpendingTransactions(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        let limit = max(spendingTransactionsByBudget[budgetID]?.nextOffset ?? transactionPageSize, transactionPageSize)
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

    func refreshCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        let maps = try await nameMaps(database)
        let transactions = try await database.fetchTransactions().filter { transaction in
            transaction.belongs(toCategory: categoryID, month: month)
        }
        categoryTransactionsByKey[categoryTransactionKey(budgetID, categoryID, month)] = TransactionFeedPage(
            loaded: LoadedAccountTransactions(
                transactions: transactions,
                balance: nil,
                accountNames: maps.accountNames,
                categoryNames: maps.categoryNames,
                payeeNames: maps.payeeNames,
                transferPayeeIDs: maps.transferPayeeIDs,
                transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                offBudgetAccountIDs: maps.offBudgetAccountIDs,
                reachedEnd: true
            )
        )
    }

    func loadOlderTransactions(budgetID: String, accountID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        let key = transactionKey(budgetID, accountID)
        guard let current = accountTransactionsByKey[key] else {
            try await refreshAccountTransactions(budgetID: budgetID, accountID: accountID)
            return
        }
        guard !current.loaded.reachedEnd else {
            return
        }

        let older = try await loadedAccountTransactions(
            database: database,
            budgetID: budgetID,
            accountID: accountID,
            query: nil,
            limit: transactionPageSize,
            offset: current.nextOffset
        )
        accountTransactionsByKey[key] = TransactionFeedPage(
            loaded: combinedTransactions(current.loaded, older)
        )
    }

    func loadOlderSpendingTransactions(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        guard let current = spendingTransactionsByBudget[budgetID] else {
            try await refreshSpendingTransactions(budgetID: budgetID)
            return
        }
        guard !current.loaded.reachedEnd else {
            return
        }

        let older = try await loadedSpendingTransactions(
            database: database,
            budgetID: budgetID,
            query: nil,
            limit: transactionPageSize,
            offset: current.nextOffset
        )
        spendingTransactionsByBudget[budgetID] = TransactionFeedPage(
            loaded: combinedTransactions(current.loaded, older)
        )
    }

    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        return try await loadedAccountTransactions(
            database: database,
            budgetID: budgetID,
            accountID: accountID,
            query: query,
            limit: limit,
            offset: offset
        )
    }

    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        return try await loadedSpendingTransactions(
            database: database,
            budgetID: budgetID,
            query: query,
            limit: limit,
            offset: offset
        )
    }

    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        let database = try requireDatabase(for: budgetID)
        let monthGraph = try await database.fetchBudgetMonth(month: month)
        return TransactionEditorOptions(
            accounts: try await database.fetchAccounts().filter { !$0.closed },
            categories: editorVisibleCategories(from: monthGraph),
            categoryGroups: monthGraph.editorCategoryGroups(currency: budgetCurrency(budgetID: budgetID)),
            payees: try await database.fetchPayees()
        )
    }

    func editorVisibleCategories(from month: BudgetMonth) -> [ActualCategory] {
        month.categoryGroups.flatMap { group in
            BudgetCategoryVisibility.visibleCategories(in: group).compactMap { category in
                ActualCategory(
                    id: category.id,
                    name: category.name,
                    isIncome: category.isIncome,
                    hidden: category.hidden,
                    groupID: category.groupID
                )
            }
        }
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        let database = try requireDatabase(for: budgetID)
        let maps = try await nameMaps(database)
        let transactions = try await database.fetchTransactionPage(splits: .inline, month: month).transactions.filter { transaction in
            Self.isUncategorized(
                transaction,
                month: month,
                transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                offBudgetAccountIDs: maps.offBudgetAccountIDs
            )
        }
        let loaded = LoadedUncategorizedTransactions(
            transactions: transactions,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            categoryGroups: try await editorCategoryGroups(database: database, month: month, budgetID: budgetID)
        )
        uncategorizedTransactionsByKey[uncategorizedTransactionKey(budgetID, month)] = loaded
        return loaded
    }

    func loadedAccountTransactions(
        database: BudgetDatabase,
        budgetID: String,
        accountID: String,
        query: String?,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> LoadedAccountTransactions {
        let maps = try await nameMaps(database)
        let balance = accountsByBudget[budgetID]?.first(where: { $0.account.id == accountID })?.balance
        let page = try await database.fetchTransactionPage(
            accountID: accountID,
            matching: query,
            limit: limit,
            offset: offset
        )
        return LoadedAccountTransactions(
            transactions: page.transactions,
            balance: balance,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            reachedEnd: page.reachedEnd
        )
    }

    func loadedSpendingTransactions(
        database: BudgetDatabase,
        budgetID: String,
        query: String?,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> LoadedAccountTransactions {
        let maps = try await nameMaps(database)
        let page = try await database.fetchTransactionPage(
            matching: query,
            limit: limit,
            offset: offset
        )
        return LoadedAccountTransactions(
            transactions: page.transactions,
            balance: nil,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            reachedEnd: page.reachedEnd
        )
    }

    func combinedTransactions(
        _ current: LoadedAccountTransactions,
        _ older: LoadedAccountTransactions
    ) -> LoadedAccountTransactions {
        let existingIDs = Set(current.transactions.map(transactionIdentity))
        let appended = older.transactions.filter { !existingIDs.contains(transactionIdentity($0)) }
        return LoadedAccountTransactions(
            transactions: current.transactions + appended,
            balance: older.balance ?? current.balance,
            accountNames: older.accountNames.isEmpty ? current.accountNames : older.accountNames,
            categoryNames: older.categoryNames.isEmpty ? current.categoryNames : older.categoryNames,
            payeeNames: older.payeeNames.isEmpty ? current.payeeNames : older.payeeNames,
            transferPayeeIDs: older.transferPayeeIDs.isEmpty ? current.transferPayeeIDs : older.transferPayeeIDs,
            transferAccountIDsByPayeeID: older.transferAccountIDsByPayeeID.isEmpty
                ? current.transferAccountIDsByPayeeID
                : older.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: older.offBudgetAccountIDs,
            reachedEnd: older.reachedEnd
        )
    }

    func transactionIdentity(_ transaction: ActualTransaction) -> String {
        transaction.id ?? "\(transaction.date)|\(transaction.account)|\(transaction.amount ?? 0)|\(transaction.importedPayee ?? "")"
    }

    func nativeBudgetAlerts(
        database: BudgetDatabase,
        budgetID: String,
        month: BudgetMonth,
        monthID: String,
        isTrackingBudget: Bool
    ) async throws -> [BudgetMonthAlert] {
        let maps = try await nameMaps(database)
        let transactions = try await database.fetchTransactionPage(splits: .inline, month: monthID).transactions
        let uncategorized = transactions.filter { transaction in
            Self.isUncategorized(
                transaction,
                month: monthID,
                transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                offBudgetAccountIDs: maps.offBudgetAccountIDs
            )
        }
        uncategorizedTransactionsByKey[uncategorizedTransactionKey(budgetID, monthID)] =
            LoadedUncategorizedTransactions(
                transactions: uncategorized,
                accountNames: maps.accountNames,
                categoryNames: maps.categoryNames,
                payeeNames: maps.payeeNames,
                transferPayeeIDs: maps.transferPayeeIDs,
                transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                offBudgetAccountIDs: maps.offBudgetAccountIDs,
                categoryGroups: editorCategoryGroups(from: month, budgetID: budgetID)
            )
        return Self.budgetAlerts(
            month: month,
            monthID: monthID,
            transactions: transactions,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            isTrackingBudget: isTrackingBudget
        )
    }

    static func budgetAlerts(
        month: BudgetMonth,
        monthID: String,
        transactions: [ActualTransaction],
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>,
        isTrackingBudget: Bool
    ) -> [BudgetMonthAlert] {
        var alerts: [BudgetMonthAlert] = []
        if let toBudget = toBudgetAlert(month: month) {
            alerts.append(toBudget)
        }
        if let overspending = overspendingAlert(month: month, isTrackingBudget: isTrackingBudget) {
            alerts.append(overspending)
        }
        alerts.append(contentsOf: uncategorizedAlerts(
            transactions: transactions,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: offBudgetAccountIDs,
            month: monthID
        ))
        return alerts
    }

    // Actual allows a negative To Budget amount.
    static func toBudgetAlert(month: BudgetMonth) -> BudgetMonthAlert? {
        guard month.toBudget != 0 else {
            return nil
        }
        return BudgetMonthAlert(
            kind: "toBudget",
            severity: month.toBudget > 0 ? "positive" : "warning",
            title: "To Budget",
            amount: month.toBudget,
            count: nil,
            actionTitle: nil
        )
    }

    static func overspendingAlert(month: BudgetMonth, isTrackingBudget: Bool) -> BudgetMonthAlert? {
        let overspentCount = month.categoryGroups
            .filter { !$0.isIncome }
            .flatMap { BudgetCategoryVisibility.overspentCategories(in: $0, isTrackingBudget: isTrackingBudget) }
            .filter { $0.balance < 0 }
            .count
        guard overspentCount > 0 else {
            return nil
        }
        return BudgetMonthAlert(
            kind: "overspending",
            severity: "danger",
            title: "Overspent categories",
            amount: nil,
            count: overspentCount,
            actionTitle: "Cover"
        )
    }

    static func uncategorizedAlerts(
        transactions: [ActualTransaction],
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>,
        month: String
    ) -> [BudgetMonthAlert] {
        let count = transactions.filter {
            isUncategorized(
                $0,
                month: month,
                transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
                offBudgetAccountIDs: offBudgetAccountIDs
            )
        }.count
        guard count > 0 else {
            return []
        }
        return [
            BudgetMonthAlert(
                kind: "uncategorizedTransactions",
                severity: "warning",
                title: "Uncategorized transactions",
                amount: nil,
                count: count,
                actionTitle: "Review"
            )
        ]
    }

    // Cross-budget transfers from a budget account still need a category.
    // Split parents are excluded because their effective category is always
    // null; uncategorized children are independent `.inline` rows.
    static func isUncategorized(
        _ transaction: ActualTransaction,
        month: String,
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> Bool {
        let destinationAccountID = transaction.payee.flatMap { transferAccountIDsByPayeeID[$0] }
        let isOnBudgetTransfer = destinationAccountID.map { !offBudgetAccountIDs.contains($0) } ?? false
        return transaction.date.hasPrefix(month)
            && !offBudgetAccountIDs.contains(transaction.account)
            && (transaction.category?.isEmpty ?? true)
            && transaction.subtransactions.isEmpty
            && !transaction.isParent
            && !isOnBudgetTransfer
    }

    func editorCategoryGroups(
        database: BudgetDatabase,
        month: String,
        budgetID: String
    ) async throws -> [TransactionEditorCategoryGroup] {
        let budgetMonth = try await database.fetchBudgetMonth(month: month)
        return budgetMonth.editorCategoryGroups(currency: budgetCurrency(budgetID: budgetID))
    }

    func editorCategoryGroups(
        from budgetMonth: BudgetMonth,
        budgetID: String
    ) -> [TransactionEditorCategoryGroup] {
        budgetMonth.editorCategoryGroups(currency: budgetCurrency(budgetID: budgetID))
    }

    func nameMaps(
        _ database: BudgetDatabase
    ) async throws -> (
        accountNames: [String: String],
        categoryNames: [String: String],
        payeeNames: [String: String],
        transferPayeeIDs: Set<String>,
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) {
        let accounts = try await database.fetchAccounts()
        let categories = try await database.fetchCategories()
        let payees = try await database.fetchPayees()
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let categoryNames = Dictionary(uniqueKeysWithValues: categories.compactMap { category in
            category.id.map { ($0, category.name) }
        })
        // Transfer payees display the linked account name.
        let payeeNames = Dictionary(uniqueKeysWithValues: payees.compactMap { payee -> (String, String)? in
            guard let id = payee.id else {
                return nil
            }
            if payee.name.isEmpty, let transferAccount = payee.transferAccount, let accountName = accountNames[transferAccount] {
                return (id, accountName)
            }
            return (id, payee.name)
        })
        let transferPayeeIDs = Set(payees.compactMap { payee -> String? in
            payee.transferAccount != nil ? payee.id : nil
        })
        let transferAccountIDsByPayeeID = Dictionary(uniqueKeysWithValues: payees.compactMap { payee -> (String, String)? in
            guard let id = payee.id, let transferAccount = payee.transferAccount else {
                return nil
            }
            return (id, transferAccount)
        })
        let offBudgetAccountIDs = Set(accounts.filter(\.offbudget).map(\.id))
        return (accountNames, categoryNames, payeeNames, transferPayeeIDs, transferAccountIDsByPayeeID, offBudgetAccountIDs)
    }

    func transactionKey(_ budgetID: String, _ accountID: String) -> String {
        "\(budgetID)|\(accountID)"
    }

    func categoryTransactionKey(_ budgetID: String, _ categoryID: String, _ month: String) -> String {
        "\(budgetID)|\(categoryID)|\(month)"
    }

    func uncategorizedTransactionKey(_ budgetID: String, _ month: String) -> String {
        "\(budgetID)|\(month)"
    }

    func availableMonths(budgetID: String) async throws -> [String] {
        if let months = monthsByBudget[budgetID] {
            return months
        }
        let months = try await requireDatabase(for: budgetID).fetchAvailableMonths()
        monthsByBudget[budgetID] = months
        return months
    }

}

extension BudgetMonth {
    // Builds the category picker groups used by the transaction editor and the
    // overspent cover source picker. A synthetic "To Budget" group (backed by the
    // first visible income category) is prepended so available income can be
    // selected as a source/destination, matching Actual's budgeting model.
    func editorCategoryGroups(currency: BudgetCurrency = .usd) -> [TransactionEditorCategoryGroup] {
        let incomeGroups = categoryGroups.filter { $0.isIncome }
        let expenseGroups = categoryGroups.filter { !$0.isIncome }

        var result: [TransactionEditorCategoryGroup] = []

        if let firstIncomeCategory = incomeGroups.flatMap({ group in
            BudgetCategoryVisibility.visibleCategories(in: group)
        }).first {
            result.append(TransactionEditorCategoryGroup(
                id: "to-budget",
                name: "To Budget",
                options: [
                    TransactionEditorCategoryOption(
                        id: firstIncomeCategory.id,
                        title: "To Budget",
                        amount: toBudget,
                        valueText: currency.formatted(toBudget)
                    )
                ]
            ))
        }

        let expenseCategoryGroups = expenseGroups.compactMap { group -> TransactionEditorCategoryGroup? in
            let options = BudgetCategoryVisibility.visibleCategories(in: group)
                .filter { !$0.isIncome }
                .map { category in
                    TransactionEditorCategoryOption(
                        id: category.id,
                        title: category.name.actualistCategoryNameParts.name,
                        amount: category.balance,
                        valueText: currency.formatted(category.balance)
                    )
                }
            guard !options.isEmpty else {
                return nil
            }
            return TransactionEditorCategoryGroup(id: group.id, name: group.name, options: options)
        }

        result.append(contentsOf: expenseCategoryGroups)
        return result
    }
}
