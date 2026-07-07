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
        accountTransactionsByKey[transactionKey(budgetID, accountID)]
    }

    func cachedSpendingTransactions(budgetID: String) -> LoadedAccountTransactions? {
        spendingTransactionsByBudget[budgetID]
    }

    func refreshAccountTransactions(budgetID: String, accountID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        accountTransactionsByKey[transactionKey(budgetID, accountID)] = try await loadedAccountTransactions(
            database: database, budgetID: budgetID, accountID: accountID, query: nil
        )
    }

    func refreshSpendingTransactions(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        spendingTransactionsByBudget[budgetID] = try await loadedSpendingTransactions(
            database: database, budgetID: budgetID, query: nil
        )
    }

    // Local SQLite loads the full live set at once, so there are no older pages to fetch.
    func loadOlderTransactions(budgetID: String, accountID: String) async throws {}
    func loadOlderSpendingTransactions(budgetID: String) async throws {}

    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        return try await loadedAccountTransactions(database: database, budgetID: budgetID, accountID: accountID, query: query)
    }

    func searchSpendingTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        let database = try requireDatabase(for: budgetID)
        return try await loadedSpendingTransactions(database: database, budgetID: budgetID, query: query)
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
            categoryGroups: try await editorCategoryGroups(database: database, month: month)
        )
    }

    func loadedAccountTransactions(
        database: BudgetDatabase,
        budgetID: String,
        accountID: String,
        query: String?
    ) async throws -> LoadedAccountTransactions {
        let maps = try await nameMaps(database)
        let balance = accountsByBudget[budgetID]?.first(where: { $0.account.id == accountID })?.balance
        return LoadedAccountTransactions(
            transactions: try await database.fetchTransactions(accountID: accountID, matching: query),
            balance: balance,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            reachedEnd: true
        )
    }

    func loadedSpendingTransactions(
        database: BudgetDatabase,
        budgetID: String,
        query: String?
    ) async throws -> LoadedAccountTransactions {
        let maps = try await nameMaps(database)
        return LoadedAccountTransactions(
            transactions: try await database.fetchTransactions(matching: query),
            balance: nil,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            reachedEnd: true
        )
    }

    /// Derives budget banner alerts natively from SQLite, matching the REST server's shapes so
    /// the UI renders identically across backends. Every alert here is view-only: the sheets
    /// they open (uncategorized review, overspent categories) present read-only, and the
    /// to-budget banner is informational. Their embedded write actions stay disabled by the
    /// backend capability gate, exactly as in offline REST.
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

    /// Pure derivation of the full budget alert list (to-budget, overspending, uncategorized),
    /// ordered to match the REST server. Exposed for testing.
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

    /// Overspending banner counting categories that ended the month negative. The count mirrors
    /// the overspent-categories review sheet, which opens read-only in local-first mode.
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

    /// Pure derivation of the uncategorized-transactions alert, matching the REST server's
    /// wording/severity so the UI renders identically across backends. Exposed for testing.
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

    /// A top-level transaction needs categorizing when it falls in the month, carries no
    /// category, is not a split parent, and is not an on-budget-to-on-budget transfer. Transfers
    /// between an on-budget account and an off-budget account still need categories in Actual.
    static func isUncategorized(
        _ transaction: ActualTransaction,
        month: String,
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> Bool {
        let destinationAccountID = transaction.payee.flatMap { transferAccountIDsByPayeeID[$0] }
        let isOnBudgetTransfer = destinationAccountID.map { !offBudgetAccountIDs.contains($0) } ?? false
        return transaction.date.hasPrefix(month)
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

    func availableMonths(budgetID: String) async throws -> [String] {
        if let months = monthsByBudget[budgetID] {
            return months
        }
        let months = try await requireDatabase(for: budgetID).fetchAvailableMonths()
        monthsByBudget[budgetID] = months
        return months
    }

}
