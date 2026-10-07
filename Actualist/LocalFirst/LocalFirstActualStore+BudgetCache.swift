import Foundation

extension LocalFirstActualStore {
    /// Recompute the selected month even for backdated writes; its balance may
    /// depend on any earlier rollover month. External reads do not change selection.
    func reloadSelectedBudgetCache(budgetID: String, now: Date = Date()) async throws {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        invalidateScheduleCache(budgetID: budgetID)
        budgetReadGeneration &+= 1
        cachePublicationRevision &+= 1
        monthsByBudget[budgetID] = nil
        templateBrowserByBudget[budgetID] = nil
        let prefix = "\(budgetID)|"
        // Open feeds observe these snapshots directly. Replace their contents
        // after a write instead of evicting them until the screen is reopened.
        let categoryScopes = categoryTransactionsByKey.keys.filter { $0.hasPrefix(prefix) }.compactMap { key in
            let scope = key.dropFirst(prefix.count).split(separator: "|", maxSplits: 1)
            return scope.count == 2 ? (categoryID: String(scope[0]), month: String(scope[1])) : nil
        }
        let uncategorizedMonths = uncategorizedTransactionsByKey.keys.filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        // One name-map read and one table read serve every cached feed.
        if !categoryScopes.isEmpty || !uncategorizedMonths.isEmpty {
            let maps = try await nameMaps(database)
            if !categoryScopes.isEmpty {
                let transactions = try await database.fetchTransactions()
                for scope in categoryScopes {
                    try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                    publishCategoryTransactions(
                        budgetID: budgetID, categoryID: scope.categoryID, month: scope.month,
                        allTransactions: transactions, maps: maps
                    )
                }
            }
            if !uncategorizedMonths.isEmpty {
                let rows = try await database.fetchUncategorizedTransactions()
                for month in uncategorizedMonths {
                    _ = try await publishUncategorizedTransactions(
                        database: database, budgetID: budgetID, month: month,
                        generation: generation, rows: rows, maps: maps
                    )
                }
            }
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        }
        guard let selected = loadedBudgetMonthsByBudget[budgetID]?.selectedMonth else { return }
        let loaded = try await readBudgetMonth(budgetID: budgetID, month: selected, now: now)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        guard loadedBudgetMonthsByBudget[budgetID]?.selectedMonth == selected else { return }
        loadedBudgetMonthsByBudget[budgetID] = loaded
        currencyByBudget[budgetID] = loaded.currency
    }
}
