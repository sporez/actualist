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
        let tracking = try await LaunchSignpost.measure(LaunchStage.budgetModeLookup) {
            try await requireDatabase(for: budgetID).isTrackingBudget()
        }
        let selected = tracking || months.contains(preferredMonth) ? preferredMonth : (months.last ?? preferredMonth)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: selected)
    }

    /// Reads one month for an external snapshot without changing the month the
    /// Budget screen currently owns in `loadedBudgetMonthsByBudget`.
    func fetchBudgetMonthUncached(
        budgetID: String,
        month: String
    ) async throws -> (month: BudgetMonth, currency: BudgetCurrency) {
        let database = try requireDatabase(for: budgetID)
        let snapshot = try await database.fetchBudgetSnapshot(month: month)
        return (snapshot.month, snapshot.currency)
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        let loaded = try await readBudgetMonth(budgetID: budgetID, month: selectedMonth)
        loadedBudgetMonthsByBudget[budgetID] = loaded
        currencyByBudget[budgetID] = loaded.currency
        return loaded
    }

    /// External readers share the financial snapshot without moving the screen.
    func readBudgetMonth(budgetID: String, month monthID: String, now: Date = Date()) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        while true {
            try Task.checkCancellation()
            let generation = budgetReadGeneration
            let launchRevision = try? launchSnapshotFiles?.prepareRevision()
            let snapshot = try await database.fetchBudgetSnapshot(month: monthID, now: now)
            let month = snapshot.month
            let isTracking = month.trackingSummary != nil
            let alerts = try await LaunchSignpost.measure(LaunchStage.budgetAlertCalculation) {
                try await budgetAlertSnapshot(
                    database: database, month: month, isTrackingBudget: isTracking
                )
            }
            let loaded = LoadedBudgetMonth(
                modeIdentity: snapshot.modeIdentity,
                availableMonths: snapshot.availableMonths,
                selectedMonth: monthID,
                month: month,
                alerts: alerts,
                currency: snapshot.currency,
                isTrackingBudget: isTracking
            )
            let currentIdentity = try await LaunchSignpost.measure(LaunchStage.budgetIdentityValidation) {
                try await database.fetchBudgetModeIdentity()
            }
            try Task.checkCancellation()
            guard self.database === database, openedBudgetID == budgetID else { throw CancellationError() }
            // Another same-budget write may finish while alerts are read. Retry
            // its snapshot rather than report a committed write as cancelled.
            guard generation == budgetReadGeneration, currentIdentity == snapshot.modeIdentity else { continue }
            if let launchRevision {
                persistBudgetLaunchSnapshotIfCanonical(loaded, revision: launchRevision)
            }
            return loaded
        }
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
        let transactions = try await database.fetchUncategorizedTransactions().filter { transaction in
            Self.isUncategorized(
                transaction,
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

    func budgetAlertSnapshot(
        database: BudgetDatabase,
        month: BudgetMonth,
        isTrackingBudget: Bool
    ) async throws -> [BudgetMonthAlert] {
        var alerts: [BudgetMonthAlert] = []
        if !isTrackingBudget, let toBudget = Self.toBudgetAlert(month: month) {
            alerts.append(toBudget)
        }
        if let overspending = Self.overspendingAlert(
            month: month,
            isTrackingBudget: isTrackingBudget
        ) {
            alerts.append(overspending)
        }
        let uncategorizedCount = try await database.fetchUncategorizedTransactionCount()
        if let uncategorized = Self.uncategorizedAlert(count: uncategorizedCount) {
            alerts.append(uncategorized)
        }
        return alerts
    }

    static func budgetAlerts(
        month: BudgetMonth,
        transactions: [ActualTransaction],
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>,
        isTrackingBudget: Bool
    ) -> [BudgetMonthAlert] {
        var alerts: [BudgetMonthAlert] = []
        if !isTrackingBudget, let toBudget = toBudgetAlert(month: month) {
            alerts.append(toBudget)
        }
        if let overspending = overspendingAlert(month: month, isTrackingBudget: isTrackingBudget) {
            alerts.append(overspending)
        }
        alerts.append(contentsOf: uncategorizedAlerts(
            transactions: transactions,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: offBudgetAccountIDs
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
            actionTitle: isTrackingBudget ? "Review" : "Cover"
        )
    }

    static func uncategorizedAlert(count: Int) -> BudgetMonthAlert? {
        guard count > 0 else { return nil }
        return BudgetMonthAlert(
            kind: "uncategorizedTransactions",
            severity: "warning",
            title: "Uncategorized transactions",
            amount: nil,
            count: count,
            actionTitle: "Review"
        )
    }

    static func uncategorizedAlerts(
        transactions: [ActualTransaction],
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> [BudgetMonthAlert] {
        let count = transactions.filter {
            isUncategorized(
                $0,
                transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
                offBudgetAccountIDs: offBudgetAccountIDs
            )
        }.count
        return uncategorizedAlert(count: count).map { [$0] } ?? []
    }

    // Cross-budget transfers from a budget account still need a category.
    // Split parents are excluded because their effective category is always
    // null; uncategorized children are independent `.inline` rows.
    // Uncategorized is budget-global: prior months still reduce To Budget,
    // and Actual web's banner has no month filter.
    static func isUncategorized(
        _ transaction: ActualTransaction,
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> Bool {
        let destinationAccountID = transaction.payee.flatMap { transferAccountIDsByPayeeID[$0] }
        let isOnBudgetTransfer = destinationAccountID.map { !offBudgetAccountIDs.contains($0) } ?? false
        return !offBudgetAccountIDs.contains(transaction.account)
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
        let payees = try await database.fetchPayees(orderedForPicker: false)
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
        let months = try await LaunchSignpost.measure(LaunchStage.budgetAvailableMonths) {
            try await requireDatabase(for: budgetID).fetchAvailableMonths()
        }
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

        if trackingSummary == nil, let firstIncomeCategory = incomeGroups.flatMap({ group in
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

        let displayedGroups = trackingSummary == nil ? expenseGroups : categoryGroups
        let pickerGroups = displayedGroups.compactMap { group -> TransactionEditorCategoryGroup? in
            let options = BudgetCategoryVisibility.visibleCategories(in: group)
                .filter { trackingSummary != nil || !$0.isIncome }
                .map { category in
                    let amount = category.isIncome ? nil : Optional(category.balance)
                    return TransactionEditorCategoryOption(
                        id: category.id,
                        title: category.name.actualistCategoryNameParts.name,
                        amount: amount,
                        valueText: amount.map(currency.formatted)
                    )
                }
            guard !options.isEmpty else {
                return nil
            }
            return TransactionEditorCategoryGroup(id: group.id, name: group.name, options: options)
        }

        result.append(contentsOf: pickerGroups)
        return result
    }
}
