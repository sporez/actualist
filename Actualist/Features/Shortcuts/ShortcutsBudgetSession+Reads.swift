import Foundation

extension ShortcutsBudgetSession {
    static let suggestedTransactionLimit = 50
    static let maximumTransactionLimit = 100
    static let defaultTransactionLimit = 25

    func account(id: String, includeClosed: Bool = true) async throws -> AccountEntity {
        let accounts = try await accounts(includeClosed: includeClosed)
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw ShortcutsError.accountNotFound
        }
        return account
    }

    func category(
        id: String,
        includeHidden: Bool = true,
        includeIncome: Bool = true,
        month: String? = nil
    ) async throws -> CategoryEntity {
        let categories = try await categories(
            includeHidden: includeHidden,
            includeIncome: includeIncome,
            month: month
        )
        guard let category = categories.first(where: { $0.id == id }) else {
            throw ShortcutsError.categoryNotFound
        }
        return category
    }

    func payee(id: String, includeTransfers: Bool = true) async throws -> PayeeEntity {
        let payees = try await payees(includeTransfers: includeTransfers)
        guard let payee = payees.first(where: { $0.id == id }) else {
            throw ShortcutsError.payeeNotFound
        }
        return payee
    }

    func budgetSummary(month: String? = nil) async throws -> BudgetSummaryEntity {
        let loaded = try await loadedMonth(preferred: month)
        return BudgetSummaryEntity.make(from: loaded)
    }

    func overspentCategories(month: String? = nil) async throws -> [CategoryEntity] {
        let loaded = try await loadedMonth(preferred: month)
        return loaded.month.categoryGroups.flatMap { group in
            group.categories.compactMap { category in
                let isHidden = category.hidden ?? false
                guard !isHidden, !category.isIncome, category.balance < 0 else {
                    return nil
                }
                return CategoryEntity.make(
                    from: category,
                    groupName: group.name,
                    currency: loaded.currency
                )
            }
        }
    }

    func budgetAlerts(month: String? = nil) async throws -> [BudgetAlertEntity] {
        let loaded = try await loadedMonth(preferred: month)
        return loaded.alerts.map { alert in
            BudgetAlertEntity.make(from: alert, month: loaded.selectedMonth, currency: loaded.currency)
        }
    }

    func uncategorizedTransactions(
        month: String? = nil,
        limit: Int = defaultTransactionLimit
    ) async throws -> [TransactionEntity] {
        let loaded = try await uncategorizedPayload(month: month)
        let prepared = try await prepare()
        let capped = Self.cappedTransactionLimit(limit)
        return loaded.transactions.prefix(capped).compactMap { transaction in
            TransactionEntity.make(from: transaction, maps: .init(loaded), currency: prepared.currency)
        }
    }

    func uncategorizedCount(month: String? = nil) async throws -> Int {
        try await uncategorizedPayload(month: month).transactions.count
    }

    func transactions(
        accountID: String? = nil,
        search: String? = nil,
        limit: Int = defaultTransactionLimit
    ) async throws -> [TransactionEntity] {
        let prepared = try await prepare()
        let capped = Self.cappedTransactionLimit(limit)
        let loaded = try await transactionPayload(
            store: prepared.store,
            budgetID: prepared.budgetID,
            accountID: accountID,
            search: search,
            limit: capped
        )
        return loaded.transactions.prefix(capped).compactMap { transaction in
            TransactionEntity.make(from: transaction, maps: .init(loaded), currency: prepared.currency)
        }
    }

    func transaction(id: String) async throws -> TransactionEntity {
        let original = try await actualTransaction(id: id)
        let maps = try await nameMaps(for: original)
        let prepared = try await prepare()
        guard let entity = TransactionEntity.make(from: original, maps: maps, currency: prepared.currency) else {
            throw ShortcutsError.transactionNotFound
        }
        return entity
    }

    func transactions(ids: [String]) async throws -> [TransactionEntity] {
        var results: [TransactionEntity] = []
        results.reserveCapacity(ids.count)
        for id in ids {
            do {
                results.append(try await transaction(id: id))
            } catch ShortcutsError.transactionNotFound {
                continue
            }
        }
        return results
    }

    func actualTransaction(id: String) async throws -> ActualTransaction {
        let prepared = try await prepare()
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShortcutsError.transactionNotFound
        }
        guard let match = try await prepared.store.fetchTransaction(
            budgetID: prepared.budgetID,
            id: trimmed
        ) else {
            throw ShortcutsError.transactionNotFound
        }
        return match
    }

    func nameMaps(for transaction: ActualTransaction) async throws -> TransactionNameMaps {
        let prepared = try await prepare()
        try await prepared.store.refreshAccountTransactions(
            budgetID: prepared.budgetID,
            accountID: transaction.account
        )
        if let loaded = prepared.store.cachedAccountTransactions(
            budgetID: prepared.budgetID,
            accountID: transaction.account
        ) {
            return TransactionNameMaps(loaded)
        }
        return TransactionNameMaps(
            accountNames: [:],
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: []
        )
    }

    func transferPayee(forAccountID accountID: String) async throws -> PayeeEntity {
        let payees = try await payees(includeTransfers: true)
        guard let payee = payees.first(where: { $0.transferAccountID == accountID }) else {
            throw ShortcutsError.transferDestinationMissing
        }
        return payee
    }

    func reportsDashboard(month: String? = nil) async throws -> ReportsDashboardSnapshot {
        let prepared = try await prepare()
        let loaded = try await loadedMonth(preferred: month)
        let range = Self.reportRange(for: loaded.selectedMonth)
        if let cached = prepared.store.cachedReportsDashboard(budgetID: prepared.budgetID, range: range) {
            return cached
        }
        return try await prepared.store.refreshReportsDashboard(
            budgetID: prepared.budgetID,
            range: range
        )
    }

    static func cappedTransactionLimit(_ limit: Int) -> Int {
        min(max(limit, 1), maximumTransactionLimit)
    }

    static func reportRange(for monthID: String) -> ReportDateRange {
        let calendar = ReportCalendar.gregorianLocal
        guard let monthStart = ReportCalendar.date(fromMonthID: monthID, calendar: calendar) else {
            return .dashboard(through: Date())
        }
        let today = calendar.startOfDay(for: Date())
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) ?? monthStart
        let currentMonthID = ReportCalendar.monthID(for: today, calendar: calendar)
        let through = monthID == currentMonthID ? today : monthEnd
        return .dashboard(through: through, calendar: calendar)
    }

    private func uncategorizedPayload(month: String? = nil) async throws -> LoadedUncategorizedTransactions {
        let prepared = try await prepare()
        let loadedMonth = try await loadedMonth(preferred: month)
        if let cached = prepared.store.cachedUncategorizedTransactions(
            budgetID: prepared.budgetID,
            month: loadedMonth.selectedMonth
        ) {
            return cached
        }
        return try await prepared.store.uncategorizedTransactions(
            budgetID: prepared.budgetID,
            month: loadedMonth.selectedMonth
        )
    }

    private func transactionPayload(
        store: LocalFirstActualStore,
        budgetID: String,
        accountID: String?,
        search: String?,
        limit: Int
    ) async throws -> LoadedAccountTransactions {
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = query.map { !$0.isEmpty } ?? false
        if let accountID {
            if hasQuery, let query {
                return try await store.searchAccountTransactions(
                    budgetID: budgetID,
                    accountID: accountID,
                    query: query,
                    limit: limit,
                    offset: 0
                )
            }
            if let cached = store.cachedAccountTransactions(budgetID: budgetID, accountID: accountID) {
                return cached
            }
            try await store.refreshAccountTransactions(budgetID: budgetID, accountID: accountID)
            return try requireCachedTransactions(
                store.cachedAccountTransactions(budgetID: budgetID, accountID: accountID)
            )
        }
        if hasQuery, let query {
            return try await store.searchSpendingTransactions(
                budgetID: budgetID,
                query: query,
                limit: limit,
                offset: 0
            )
        }
        if let cached = store.cachedSpendingTransactions(budgetID: budgetID) {
            return cached
        }
        try await store.refreshSpendingTransactions(budgetID: budgetID)
        return try requireCachedTransactions(store.cachedSpendingTransactions(budgetID: budgetID))
    }

    private func requireCachedTransactions(
        _ loaded: LoadedAccountTransactions?
    ) throws -> LoadedAccountTransactions {
        guard let loaded else {
            throw ShortcutsError.transactionNotFound
        }
        return loaded
    }
}

struct TransactionNameMaps {
    let accountNames: [String: String]
    let categoryNames: [String: String]
    let payeeNames: [String: String]
    let transferPayeeIDs: Set<String>

    init(
        accountNames: [String: String],
        categoryNames: [String: String],
        payeeNames: [String: String],
        transferPayeeIDs: Set<String>
    ) {
        self.accountNames = accountNames
        self.categoryNames = categoryNames
        self.payeeNames = payeeNames
        self.transferPayeeIDs = transferPayeeIDs
    }

    init(_ loaded: LoadedAccountTransactions) {
        accountNames = loaded.accountNames
        categoryNames = loaded.categoryNames
        payeeNames = loaded.payeeNames
        transferPayeeIDs = loaded.transferPayeeIDs
    }

    init(_ loaded: LoadedUncategorizedTransactions) {
        accountNames = loaded.accountNames
        categoryNames = loaded.categoryNames
        payeeNames = loaded.payeeNames
        transferPayeeIDs = loaded.transferPayeeIDs
    }
}
