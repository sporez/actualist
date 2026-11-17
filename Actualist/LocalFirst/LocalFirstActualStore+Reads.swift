import Foundation

extension LocalFirstActualStore {
    func cachedBudgetMonth(budgetID: String) -> LoadedBudgetMonth? {
        loadedBudgetMonthsByBudget[budgetID]
    }

    func budgetCurrency(budgetID: String) -> BudgetCurrency {
        currencyByBudget[budgetID] ?? .usd
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
            let launchRevision = try? await launchSnapshotFiles?.loadRevision()
            let snapshot = try await BudgetMonthSQL.fetchBudgetSnapshot(month: monthID, now: now, in: database)
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
                try await BudgetModeSQL.fetchBudgetModeIdentity(in: database)
            }
            try Task.checkCancellation()
            guard self.database === database, openedBudgetID == budgetID else { throw CancellationError() }
            // Another same-budget write may finish while alerts are read. Retry
            // its snapshot rather than report a committed write as cancelled.
            guard generation == budgetReadGeneration, currentIdentity == snapshot.modeIdentity else { continue }
            if let launchRevision {
                await budgetLaunch.persistBudgetLaunchSnapshotIfCanonical(loaded, revision: launchRevision)
            }
            return loaded
        }
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
        let uncategorizedCount = try await TransactionReadSQL.fetchUncategorizedTransactionCount(in: database)
        if let uncategorized = Self.uncategorizedAlert(count: uncategorizedCount) {
            alerts.append(uncategorized)
        }
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

    func availableMonths(budgetID: String) async throws -> [String] {
        if let months = monthsByBudget[budgetID] {
            return months
        }
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let revision = cachePublicationRevision
        let months = try await LaunchSignpost.measure(LaunchStage.budgetAvailableMonths) {
            try await BudgetMonthSQL.fetchAvailableMonths(in: database)
        }
        #if DEBUG
        await testSeams?.readPublicationHook?(.availableMonths)
        #endif
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        if revision == cachePublicationRevision {
            monthsByBudget[budgetID] = months
        }
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
                        valueText: currency.formatted(toBudget),
                        isToBudget: true
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
