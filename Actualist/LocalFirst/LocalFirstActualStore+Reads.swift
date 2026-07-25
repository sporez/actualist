import Foundation

extension LocalFirstActualStore {
    func budgets() async throws -> [ActualBudget] {
        cachedBudgets
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
        return LoadedBudgetMonth(
            availableMonths: months,
            selectedMonth: monthID,
            month: month,
            alerts: try await nativeBudgetAlerts(database: database, month: month, monthID: monthID)
        )
    }

    func accountDisplays(budgetID: String) -> [AccountDisplay] {
        accountsByBudget[budgetID] ?? []
    }

    func refreshAccountsWithBalances(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        accountsByBudget[budgetID] = try await database.fetchAccountDisplays()
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
        return TransactionEditorOptions(
            accounts: try await database.fetchAccounts().filter { !$0.closed },
            categories: try await database.fetchCategories().filter { !($0.hidden ?? false) && !($0.isIncome ?? false) },
            categoryGroups: try await editorCategoryGroups(database: database, month: month),
            payees: try await database.fetchPayees()
        )
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        let database = try requireDatabase(for: budgetID)
        let maps = try await nameMaps(database)
        let transactions = try await database.fetchTransactions().filter { transaction in
            Self.isUncategorized(
                transaction,
                month: month,
                transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                offBudgetAccountIDs: maps.offBudgetAccountIDs
            )
        }
        return LoadedUncategorizedTransactions(
            transactions: transactions,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            categoryGroups: try await editorCategoryGroups(database: database, month: month)
        )
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

    /// Derives budget banner alerts natively from SQLite, matching Actual's alert shapes so the
    /// UI renders consistently from the local-first store.
    func nativeBudgetAlerts(
        database: BudgetDatabase,
        month: BudgetMonth,
        monthID: String
    ) async throws -> [APIBudgetMonthAlert] {
        let maps = try await nameMaps(database)
        let transactions = try await database.fetchTransactions()
        return Self.budgetAlerts(
            month: month,
            monthID: monthID,
            transactions: transactions,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs
        )
    }

    /// Pure derivation of the full budget alert list (to-budget, overspending, uncategorized).
    /// Exposed for testing.
    static func budgetAlerts(
        month: BudgetMonth,
        monthID: String,
        transactions: [ActualTransaction],
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> [APIBudgetMonthAlert] {
        var alerts: [APIBudgetMonthAlert] = []
        if let toBudget = toBudgetAlert(month: month) {
            alerts.append(toBudget)
        }
        if let overspending = overspendingAlert(month: month) {
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

    /// "To Budget" banner showing the amount left to assign this month. Informational only
    /// (non-actionable). A surplus reads positive; a negative value means the month is
    /// overbudgeted (Actual allows this) and reads as a warning, carrying the signed amount.
    static func toBudgetAlert(month: BudgetMonth) -> APIBudgetMonthAlert? {
        guard month.toBudget != 0 else {
            return nil
        }
        return APIBudgetMonthAlert(
            kind: "toBudget",
            severity: month.toBudget > 0 ? "positive" : "warning",
            title: "To Budget",
            amount: month.toBudget,
            count: nil,
            actionTitle: nil
        )
    }

    /// Raw overspending alert counting categories that ended the month negative. The Budget
    /// feature applies the user's rollover-category alert preference to this count and its
    /// overspent-categories review sheet.
    static func overspendingAlert(month: BudgetMonth) -> APIBudgetMonthAlert? {
        let overspentCount = month.categoryGroups
            .filter { !$0.isIncome }
            .flatMap(\.categories)
            .filter { !($0.hidden ?? false) && $0.balance < 0 }
            .count
        guard overspentCount > 0 else {
            return nil
        }
        return APIBudgetMonthAlert(
            kind: "overspending",
            severity: "danger",
            title: "Overspent categories",
            amount: nil,
            count: overspentCount,
            actionTitle: "Cover"
        )
    }

    /// Pure derivation of the uncategorized-transactions alert. Exposed for testing.
    static func uncategorizedAlerts(
        transactions: [ActualTransaction],
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>,
        month: String
    ) -> [APIBudgetMonthAlert] {
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
            APIBudgetMonthAlert(
                kind: "uncategorizedTransactions",
                severity: "warning",
                title: "Uncategorized transactions",
                amount: nil,
                count: count,
                actionTitle: "Review"
            )
        ]
    }

    /// A top-level on-budget transaction needs categorizing when it falls in the month, carries
    /// no category, is not a split parent, and is not an on-budget-to-on-budget transfer.
    /// Transfers from an on-budget account to an off-budget account still need categories in
    /// Actual, while transactions whose source account is off budget do not.
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

    func editorCategoryGroups(database: BudgetDatabase, month: String) async throws -> [TransactionEditorCategoryGroup] {
        let budgetMonth = try await database.fetchBudgetMonth(month: month)
        return budgetMonth.categoryGroups.compactMap { group in
            guard !group.isIncome else {
                return nil
            }
            let options = group.categories
                .filter { !($0.hidden ?? false) && !$0.isIncome }
                .map { category in
                    TransactionEditorCategoryOption(
                        id: category.id,
                        title: category.name.actualistCategoryNameParts.name,
                        amount: category.balance,
                        valueText: category.balance.actualMoney.formatted()
                    )
                }
            guard !options.isEmpty else {
                return nil
            }
            return TransactionEditorCategoryGroup(id: group.id, name: group.name, options: options)
        }
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
        // Transfer payees carry an empty name; display them as the linked account's name.
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

    func availableMonths(budgetID: String) async throws -> [String] {
        if let months = monthsByBudget[budgetID] {
            return months
        }
        let months = try await requireDatabase(for: budgetID).fetchAvailableMonths()
        monthsByBudget[budgetID] = months
        return months
    }

}
