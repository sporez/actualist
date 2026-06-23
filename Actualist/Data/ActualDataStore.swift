import Foundation
import Observation

struct ActualDataStoreSnapshot: Codable, Sendable {
    let savedAt: Date
    let budgets: SnapshotCacheEntry<[ActualBudget]>?
    let accountsByBudget: [String: SnapshotCacheEntry<[ActualAccount]>]
    let categoriesByBudget: [String: SnapshotCacheEntry<[ActualCategory]>]
    let payeesByBudget: [String: SnapshotCacheEntry<[ActualPayee]>]
    let monthsByBudget: [String: SnapshotCacheEntry<[String]>]
    let balancesByAccount: [String: SnapshotCacheEntry<Int>]
    let transactionsByAccount: [String: SnapshotCacheEntry<ActualDataStore.AccountTransactionsPage>]
    let monthByKey: [String: SnapshotCacheEntry<BudgetMonth>]
    let alertsByKey: [String: SnapshotCacheEntry<[APIBudgetMonthAlert]>]

    struct SnapshotCacheEntry<Value: Codable & Sendable>: Codable, Sendable {
        let value: Value
        let fetchedAt: Date
    }
}

/// Single in-memory source of truth for fetched API data.
///
/// Caching strategy (agreed with product): **stale-while-revalidate with hard
/// invalidation**. Screens read the observable cached snapshots for instant display,
/// then call a `refresh*` method to revalidate in the background; the view updates when
/// fresh data lands. Every write invalidates exactly the affected cache keys and refetches
/// them, so dependent screens never render pre-write data. The cache is memory-only and is
/// cleared via `reset()` on budget switch / connection change / logout.
@MainActor
@Observable
final class ActualDataStore {
    struct CacheEntry<Value> {
        var value: Value
        var fetchedAt: Date
    }

    struct AccountTransactionsPage: Codable, Hashable, Sendable {
        var transactions: [ActualTransaction]
        var oldestLoadedDate: Date
        var reachedEnd: Bool
    }

    /// Reference data older than this is refetched by `ensure*` (secondary) reads.
    /// Appear-driven `refresh*` calls always revalidate regardless of this window.
    private static let referenceTTL: TimeInterval = 300
    private static let transactionWindowDays = 90

    // Reference resources (slow-changing, reused across screens).
    private(set) var budgets: CacheEntry<[ActualBudget]>?
    private(set) var accountsByBudget: [String: CacheEntry<[ActualAccount]>] = [:]
    private(set) var categoriesByBudget: [String: CacheEntry<[ActualCategory]>] = [:]
    private(set) var payeesByBudget: [String: CacheEntry<[ActualPayee]>] = [:]
    private(set) var monthsByBudget: [String: CacheEntry<[String]>] = [:]

    // Money-truth resources (per account / per month).
    private(set) var balancesByAccount: [String: CacheEntry<Int>] = [:]
    private(set) var transactionsByAccount: [String: CacheEntry<AccountTransactionsPage>] = [:]
    private(set) var monthByKey: [String: CacheEntry<BudgetMonth>] = [:]
    private(set) var alertsByKey: [String: CacheEntry<[APIBudgetMonthAlert]>] = [:]

    @ObservationIgnored private let clientProvider: () -> ActualAPIClientProtocol?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let snapshotDidChange: () -> Void
    @ObservationIgnored private let networkDidStart: () -> Void
    @ObservationIgnored private let networkDidSucceed: () -> Void
    @ObservationIgnored private let networkDidFail: (Error) -> Void
    @ObservationIgnored private var inFlight: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var invalidatedTransactionPagesByAccount: [String: AccountTransactionsPage] = [:]

    init(
        clientProvider: @escaping () -> ActualAPIClientProtocol?,
        now: @escaping () -> Date = Date.init,
        snapshotDidChange: @escaping () -> Void = {},
        networkDidStart: @escaping () -> Void = {},
        networkDidSucceed: @escaping () -> Void = {},
        networkDidFail: @escaping (Error) -> Void = { _ in }
    ) {
        self.clientProvider = clientProvider
        self.now = now
        self.snapshotDidChange = snapshotDidChange
        self.networkDidStart = networkDidStart
        self.networkDidSucceed = networkDidSucceed
        self.networkDidFail = networkDidFail
    }

    // MARK: - Keys

    private func accountKey(_ budgetID: String, _ accountID: String) -> String {
        "\(budgetID)|\(accountID)"
    }

    private func monthKey(_ budgetID: String, _ month: String) -> String {
        "\(budgetID)|\(month)"
    }

    // MARK: - Reset / invalidation

    /// Clears the entire cache. Call when the active budget, server, or credentials change so
    /// data from another context can never appear.
    func reset() {
        budgets = nil
        accountsByBudget = [:]
        categoriesByBudget = [:]
        payeesByBudget = [:]
        monthsByBudget = [:]
        balancesByAccount = [:]
        transactionsByAccount = [:]
        invalidatedTransactionPagesByAccount = [:]
        monthByKey = [:]
        alertsByKey = [:]
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
    }

    func restore(_ snapshot: ActualDataStoreSnapshot) {
        budgets = snapshot.budgets.map { CacheEntry(snapshot: $0) }
        accountsByBudget = snapshot.accountsByBudget.mapValues { CacheEntry(snapshot: $0) }
        categoriesByBudget = snapshot.categoriesByBudget.mapValues { CacheEntry(snapshot: $0) }
        payeesByBudget = snapshot.payeesByBudget.mapValues { CacheEntry(snapshot: $0) }
        monthsByBudget = snapshot.monthsByBudget.mapValues { CacheEntry(snapshot: $0) }
        balancesByAccount = snapshot.balancesByAccount.mapValues { CacheEntry(snapshot: $0) }
        transactionsByAccount = snapshot.transactionsByAccount.mapValues { CacheEntry(snapshot: $0) }
        monthByKey = snapshot.monthByKey.mapValues { CacheEntry(snapshot: $0) }
        alertsByKey = snapshot.alertsByKey.mapValues { CacheEntry(snapshot: $0) }
        invalidatedTransactionPagesByAccount = [:]
    }

    func snapshot() -> ActualDataStoreSnapshot {
        ActualDataStoreSnapshot(
            savedAt: now(),
            budgets: budgets.map(ActualDataStoreSnapshot.SnapshotCacheEntry.init),
            accountsByBudget: accountsByBudget.mapValues(ActualDataStoreSnapshot.SnapshotCacheEntry.init),
            categoriesByBudget: categoriesByBudget.mapValues(ActualDataStoreSnapshot.SnapshotCacheEntry.init),
            payeesByBudget: payeesByBudget.mapValues(ActualDataStoreSnapshot.SnapshotCacheEntry.init),
            monthsByBudget: monthsByBudget.mapValues(ActualDataStoreSnapshot.SnapshotCacheEntry.init),
            balancesByAccount: balancesByAccount.mapValues(ActualDataStoreSnapshot.SnapshotCacheEntry.init),
            transactionsByAccount: transactionsByAccount.mapValues(ActualDataStoreSnapshot.SnapshotCacheEntry.init),
            monthByKey: monthByKey.mapValues(ActualDataStoreSnapshot.SnapshotCacheEntry.init),
            alertsByKey: alertsByKey.mapValues(ActualDataStoreSnapshot.SnapshotCacheEntry.init)
        )
    }

    func hasCachedBudgetData(budgetID: String) -> Bool {
        accountsByBudget[budgetID] != nil
            || monthsByBudget[budgetID] != nil
            || monthByKey.keys.contains { $0.hasPrefix("\(budgetID)|") }
    }

    func invalidateAccount(budgetID: String, accountID: String) {
        let key = accountKey(budgetID, accountID)
        if let page = transactionsByAccount[key]?.value {
            invalidatedTransactionPagesByAccount[key] = page
        }
        transactionsByAccount[key] = nil
        balancesByAccount[key] = nil
    }

    private func invalidateAccounts(budgetID: String) {
        accountsByBudget[budgetID] = nil
        balancesByAccount = balancesByAccount.filter { !$0.key.hasPrefix("\(budgetID)|") }
    }

    func invalidateMonth(budgetID: String, month: String) {
        let key = monthKey(budgetID, month)
        monthByKey[key] = nil
        alertsByKey[key] = nil
    }

    func invalidatePayees(budgetID: String) {
        payeesByBudget[budgetID] = nil
    }

    // MARK: - Cached snapshot accessors (instant, observable reads)

    func accountDisplays(budgetID: String) -> [AccountDisplay] {
        (accountsByBudget[budgetID]?.value ?? []).map { account in
            AccountDisplay(account: account, balance: balancesByAccount[accountKey(budgetID, account.id)]?.value)
        }
    }

    /// Cached composed transactions snapshot for a screen, or `nil` if nothing is cached yet.
    func cachedAccountTransactions(budgetID: String, accountID: String) -> LoadedAccountTransactions? {
        let key = accountKey(budgetID, accountID)
        guard let page = transactionsByAccount[key]?.value else {
            return nil
        }

        return LoadedAccountTransactions(
            transactions: page.transactions,
            balance: balancesByAccount[key]?.value,
            categoryNames: categoryNames(budgetID: budgetID),
            payeeNames: payeeNames(budgetID: budgetID),
            reachedEnd: page.reachedEnd
        )
    }

    private func categoryNames(budgetID: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (categoriesByBudget[budgetID]?.value ?? []).compactMap { category in
            category.id.map { ($0, category.name) }
        })
    }

    private func payeeNames(budgetID: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (payeesByBudget[budgetID]?.value ?? []).compactMap { payee in
            payee.id.map { ($0, payee.name) }
        })
    }

    // MARK: - Reference refreshes

    func refreshBudgets() async throws {
        let client = try requireClient()
        try await coalesced("budgets") {
            let value = try await client.budgets()
            self.budgets = CacheEntry(value: value, fetchedAt: Date())
        }
    }

    func refreshAccounts(budgetID: String) async throws {
        let client = try requireClient()
        try await coalesced("accounts|\(budgetID)") {
            let value = try await client.accounts(budgetID: budgetID)
            self.accountsByBudget[budgetID] = CacheEntry(value: value, fetchedAt: Date())
        }
    }

    func refreshCategories(budgetID: String) async throws {
        let client = try requireClient()
        try await coalesced("categories|\(budgetID)") {
            let value = try await client.categories(budgetID: budgetID)
            self.categoriesByBudget[budgetID] = CacheEntry(value: value, fetchedAt: Date())
        }
    }

    func refreshPayees(budgetID: String) async throws {
        let client = try requireClient()
        try await coalesced("payees|\(budgetID)") {
            let value = try await client.payees(budgetID: budgetID)
            self.payeesByBudget[budgetID] = CacheEntry(value: value, fetchedAt: Date())
        }
    }

    func refreshBudgetMonths(budgetID: String) async throws {
        let client = try requireClient()
        try await coalesced("months|\(budgetID)") {
            let value = try await client.budgetMonths(budgetID: budgetID)
            self.monthsByBudget[budgetID] = CacheEntry(value: value, fetchedAt: Date())
        }
    }

    func ensureBudgets() async throws {
        if let budgets, Date().timeIntervalSince(budgets.fetchedAt) < Self.referenceTTL {
            return
        }
        try await refreshBudgets()
    }

    func ensureCategories(budgetID: String) async throws {
        if let entry = categoriesByBudget[budgetID], Date().timeIntervalSince(entry.fetchedAt) < Self.referenceTTL {
            return
        }
        do {
            try await refreshCategories(budgetID: budgetID)
        } catch {
            guard categoriesByBudget[budgetID] != nil else {
                throw error
            }
        }
    }

    func ensurePayees(budgetID: String) async throws {
        if let entry = payeesByBudget[budgetID], Date().timeIntervalSince(entry.fetchedAt) < Self.referenceTTL {
            return
        }
        do {
            try await refreshPayees(budgetID: budgetID)
        } catch {
            guard payeesByBudget[budgetID] != nil else {
                throw error
            }
        }
    }

    // MARK: - Money-truth refreshes

    /// Fetches accounts then their balances in parallel (replaces the previous serial N+1).
    func refreshAccountsWithBalances(budgetID: String) async throws {
        do {
            try await refreshAccounts(budgetID: budgetID)
        } catch {
            guard accountsByBudget[budgetID] != nil else {
                throw error
            }
        }

        let client = try requireClient()
        let accounts = accountsByBudget[budgetID]?.value ?? []

        let balances = try await withThrowingTaskGroup(of: (String, Int?).self) { group -> [(String, Int?)] in
            for account in accounts {
                group.addTask {
                    let balance = try? await client.balance(budgetID: budgetID, accountID: account.id)
                    return (account.id, balance)
                }
            }
            var results: [(String, Int?)] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        for (accountID, balance) in balances {
            if let balance {
                balancesByAccount[accountKey(budgetID, accountID)] = CacheEntry(value: balance, fetchedAt: Date())
            }
        }
        snapshotDidChange()
    }

    /// Revalidates the money-truth data for one account; reuses cached reference data unless stale.
    func refreshAccountTransactions(budgetID: String, accountID: String) async throws {
        try await ensureCategories(budgetID: budgetID)
        try await ensurePayees(budgetID: budgetID)

        let client = try requireClient()
        let key = accountKey(budgetID, accountID)
        try await coalesced("transactions|\(key)") {
            let existingPage = self.transactionsByAccount[key]?.value ?? self.invalidatedTransactionPagesByAccount[key]
            let oldestLoadedDate = existingPage?.oldestLoadedDate ?? self.initialTransactionSinceDate()
            async let transactions = client.transactions(
                budgetID: budgetID,
                accountID: accountID,
                since: oldestLoadedDate,
                until: nil
            )
            async let balance = client.balance(budgetID: budgetID, accountID: accountID)
            let loadedTransactions = try await transactions
            let loadedBalance = try? await balance
            self.transactionsByAccount[key] = CacheEntry(
                value: AccountTransactionsPage(
                    transactions: Self.sortedTransactions(Self.parentTransactions(from: loadedTransactions)),
                    oldestLoadedDate: oldestLoadedDate,
                    reachedEnd: existingPage?.reachedEnd ?? false
                ),
                fetchedAt: Date()
            )
            self.invalidatedTransactionPagesByAccount[key] = nil
            if let loadedBalance {
                self.balancesByAccount[key] = CacheEntry(value: loadedBalance, fetchedAt: Date())
            }
        }
    }

    func loadOlderTransactions(budgetID: String, accountID: String) async throws {
        let client = try requireClient()
        let key = accountKey(budgetID, accountID)
        try await coalesced("transactionsOlder|\(key)") {
            guard var page = self.transactionsByAccount[key]?.value, !page.reachedEnd else {
                return
            }

            let until = Self.transactionCalendar.date(byAdding: .day, value: -1, to: page.oldestLoadedDate) ?? page.oldestLoadedDate
            let since = Self.transactionCalendar.date(
                byAdding: .day,
                value: -Self.transactionWindowDays,
                to: page.oldestLoadedDate
            ) ?? page.oldestLoadedDate

            let olderTransactions = try await client.transactions(
                budgetID: budgetID,
                accountID: accountID,
                since: since,
                until: until
            )

            if olderTransactions.isEmpty {
                page.reachedEnd = true
            } else {
                page.transactions = Self.mergedTransactions(Self.parentTransactions(from: olderTransactions) + page.transactions)
                page.oldestLoadedDate = since
            }

            self.transactionsByAccount[key] = CacheEntry(value: page, fetchedAt: Date())
        }
    }

    func searchAccountTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> LoadedAccountTransactions {
        try await ensureCategories(budgetID: budgetID)
        try await ensurePayees(budgetID: budgetID)

        let client = try requireClient()
        let key = accountKey(budgetID, accountID)
        let transactions = try await client.searchTransactions(
            budgetID: budgetID,
            accountID: accountID,
            query: query,
            limit: limit,
            offset: offset
        )

        return LoadedAccountTransactions(
            transactions: Self.sortedTransactions(Self.parentTransactions(from: transactions)),
            balance: balancesByAccount[key]?.value,
            categoryNames: categoryNames(budgetID: budgetID),
            payeeNames: payeeNames(budgetID: budgetID),
            reachedEnd: true
        )
    }

    func syncBankAccountAndRefresh(
        budgetID: String,
        accountID: String
    ) async throws -> LoadedAccountTransactions? {
        let client = try requireClient()
        _ = try await client.syncBankAccount(budgetID: budgetID, accountID: accountID)
        invalidateAccount(budgetID: budgetID, accountID: accountID)
        try await refreshAccountTransactions(budgetID: budgetID, accountID: accountID)
        return cachedAccountTransactions(budgetID: budgetID, accountID: accountID)
    }

    func reconcileAccountAndRefresh(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> APIAccountReconciliationResult {
        let client = try requireClient()
        let result = try await client.reconcileAccount(
            budgetID: budgetID,
            accountID: accountID,
            statementBalance: statementBalance
        )
        guard result.reconciled else {
            return result
        }

        invalidateAccount(budgetID: budgetID, accountID: accountID)
        try await refreshAccountTransactions(budgetID: budgetID, accountID: accountID)
        return result
    }

    func refreshBudgetMonth(budgetID: String, month: String) async throws {
        let client = try requireClient()
        let key = monthKey(budgetID, month)
        try await coalesced("month|\(key)") {
            async let loadedMonth = client.budgetMonth(budgetID: budgetID, month: month)
            async let loadedAlerts = client.budgetMonthAlerts(budgetID: budgetID, month: month)
            self.monthByKey[key] = CacheEntry(value: try await loadedMonth, fetchedAt: Date())
            self.alertsByKey[key] = CacheEntry(value: try await loadedAlerts.alerts, fetchedAt: Date())
        }
    }

    // MARK: - Invalidation orchestration for writes

    /// Invalidates and refetches everything a mutation touched so the cache holds fresh values
    /// before any dependent screen reads.
    func applyInvalidation(_ changed: ChangedResources, budgetID: String, newPayeeName: String? = nil) async throws {
        if newPayeeName != nil {
            invalidatePayees(budgetID: budgetID)
            try? await refreshPayees(budgetID: budgetID)
        }

        for accountID in changed.accounts {
            invalidateAccount(budgetID: budgetID, accountID: accountID)
            try await refreshAccountTransactions(budgetID: budgetID, accountID: accountID)
        }

        for month in changed.months {
            invalidateMonth(budgetID: budgetID, month: month)
            try await refreshBudgetMonth(budgetID: budgetID, month: month)
        }
    }

    // MARK: - Coalescing

    private func coalesced(_ key: String, _ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        if let existing = inFlight[key] {
            try await existing.value
            return
        }

        networkDidStart()
        let task = Task<Void, Error> { try await operation() }
        inFlight[key] = task
        do {
            try await task.value
            inFlight[key] = nil
            networkDidSucceed()
            snapshotDidChange()
        } catch {
            inFlight[key] = nil
            networkDidFail(error)
            throw error
        }
    }

    private func requireClient() throws -> ActualAPIClientProtocol {
        guard let client = clientProvider() else {
            throw ActualAPIError.invalidURL
        }
        return client
    }

    private func initialTransactionSinceDate() -> Date {
        let today = Self.transactionCalendar.startOfDay(for: now())
        return Self.transactionCalendar.date(
            byAdding: .day,
            value: -Self.transactionWindowDays,
            to: today
        ) ?? today
    }

    private static func mergedTransactions(_ transactions: [ActualTransaction]) -> [ActualTransaction] {
        var seen: Set<String> = []
        let unique = transactions.filter { transaction in
            seen.insert(transactionIdentity(transaction)).inserted
        }
        return sortedTransactions(unique)
    }

    private static func parentTransactions(from transactions: [ActualTransaction]) -> [ActualTransaction] {
        transactions.filter { !$0.isChild && $0.parentID == nil }
    }

    private static func sortedTransactions(_ transactions: [ActualTransaction]) -> [ActualTransaction] {
        transactions.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return transactionIdentity(lhs) < transactionIdentity(rhs)
            }
            return lhs.date > rhs.date
        }
    }

    private static func transactionIdentity(_ transaction: ActualTransaction) -> String {
        transaction.id ?? "\(transaction.date)|\(transaction.account)|\(transaction.amount ?? 0)|\(transaction.importedPayee ?? "")"
    }

    private static let transactionCalendar = Calendar(identifier: .gregorian)
}

// MARK: - Composed data providers (conform to existing repository protocols)

extension ActualDataStore: BudgetRepositoryProtocol {
    func budgets() async throws -> [ActualBudget] {
        do {
            try await refreshBudgets()
        } catch {
            guard budgets != nil else {
                throw error
            }
        }
        return budgets?.value ?? []
    }

    func currentBudgetMonth(budgetID: String, preferredMonth: String) async throws -> LoadedBudgetMonth {
        do {
            try await refreshBudgetMonths(budgetID: budgetID)
        } catch {
            guard monthsByBudget[budgetID] != nil else {
                throw error
            }
        }
        let months = monthsByBudget[budgetID]?.value ?? []
        let monthID = months.contains(preferredMonth) ? preferredMonth : (months.last ?? preferredMonth)
        return try await loadedBudgetMonth(budgetID: budgetID, availableMonths: months, monthID: monthID)
    }

    func budgetMonth(budgetID: String, selectedMonth: String) async throws -> LoadedBudgetMonth {
        do {
            try await refreshBudgetMonths(budgetID: budgetID)
        } catch {
            guard monthsByBudget[budgetID] != nil else {
                throw error
            }
        }
        let months = monthsByBudget[budgetID]?.value ?? []
        let monthID = months.contains(selectedMonth) ? selectedMonth : (months.last ?? selectedMonth)
        return try await loadedBudgetMonth(budgetID: budgetID, availableMonths: months, monthID: monthID)
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void = {}
    ) async throws -> LoadedBudgetMonth {
        let client = try requireClient()
        _ = try await client.updateBudgetMonthCategory(
            budgetID: budgetID,
            month: month,
            categoryID: categoryID,
            budgeted: budgeted
        )
        await didAssign()
        invalidateMonth(budgetID: budgetID, month: month)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void = {}
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
        didMove: @escaping () async -> Void = {}
    ) async throws -> LoadedBudgetMonth {
        let client = try requireClient()
        for command in commands where command.amount > 0 {
            _ = try await client.createCategoryTransfer(
                budgetID: budgetID,
                month: month,
                fromCategoryID: command.fromCategoryID,
                toCategoryID: command.toCategoryID,
                amount: command.amount
            )
        }
        await didMove()
        invalidateMonth(budgetID: budgetID, month: month)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void = {}
    ) async throws -> LoadedBudgetMonth {
        let client = try requireClient()
        _ = try await client.applyBudgetTemplate(
            budgetID: budgetID,
            month: month,
            command: command
        )
        await didApply()
        invalidateMonth(budgetID: budgetID, month: month)
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }

    private func loadedBudgetMonth(
        budgetID: String,
        availableMonths: [String],
        monthID: String
    ) async throws -> LoadedBudgetMonth {
        let key = monthKey(budgetID, monthID)
        do {
            try await refreshBudgetMonth(budgetID: budgetID, month: monthID)
        } catch {
            guard monthByKey[key] != nil else {
                throw error
            }
        }
        guard let month = monthByKey[key]?.value else {
            throw ActualAPIError.invalidResponse
        }
        return LoadedBudgetMonth(
            availableMonths: availableMonths,
            selectedMonth: monthID,
            month: month,
            alerts: alertsByKey[key]?.value ?? []
        )
    }
}

extension ActualDataStore: TransactionRepositoryProtocol {
    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        try await ensureAccounts(budgetID: budgetID)
        try await ensureCategories(budgetID: budgetID)
        try await ensurePayees(budgetID: budgetID)
        try? await refreshBudgetMonth(budgetID: budgetID, month: month)

        return TransactionEditorOptions(
            accounts: (accountsByBudget[budgetID]?.value ?? []).filter { !$0.closed },
            categories: (categoriesByBudget[budgetID]?.value ?? []).filter { !($0.hidden ?? false) && !($0.isIncome ?? false) },
            categoryGroups: transactionEditorCategoryGroups(budgetID: budgetID, month: month),
            payees: payeesByBudget[budgetID]?.value ?? []
        )
    }

    private func transactionEditorCategoryGroups(
        budgetID: String,
        month: String
    ) -> [TransactionEditorCategoryGroup] {
        let month = monthByKey[monthKey(budgetID, month)]?.value
        return (month?.categoryGroups ?? []).compactMap { group in
            let options = group.categories.filter { !($0.hidden ?? false) }.compactMap { category -> TransactionEditorCategoryOption? in
                guard !category.isIncome else {
                    return nil
                }

                return TransactionEditorCategoryOption(
                    id: category.id,
                    title: category.name.actualistCategoryNameParts.name,
                    amount: category.balance,
                    valueText: category.balance.actualMoney.formatted()
                )
            }

            guard !group.isIncome, !options.isEmpty else {
                return nil
            }

            return TransactionEditorCategoryGroup(
                id: group.id,
                name: group.name,
                options: options
            )
        }
    }

    func previewRules(for draft: TransactionDraft, budgetID: String) async throws -> TransactionRulePreview {
        try await requireClient().runTransactionRules(budgetID: budgetID, draft: draft)
    }

    func createAccountAndRefresh(
        budgetID: String,
        name: String,
        offbudget: Bool
    ) async throws {
        let client = try requireClient()
        _ = try await client.createAccount(budgetID: budgetID, name: name, offbudget: offbudget)
        invalidateAccounts(budgetID: budgetID)
        try await refreshAccountsWithBalances(budgetID: budgetID)
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void = {}
    ) async throws -> TransactionMutationResult {
        let client = try requireClient()
        _ = try await client.createTransaction(budgetID: budgetID, draft: draft)
        let result = TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [draft.accountID],
                months: [draft.month.rawValue],
                transactions: []
            )
        )
        await didCreate()
        try await applyInvalidation(
            result.changed,
            budgetID: budgetID,
            newPayeeName: draft.payeeID == nil ? draft.payeeName : nil
        )
        return result
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void = {}
    ) async throws -> TransactionMutationResult {
        let client = try requireClient()
        _ = try await client.updateTransaction(budgetID: budgetID, transactionID: transactionID, draft: draft)
        let result = TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: Self.uniquePreservingOrder([originalAccountID, draft.accountID]),
                months: Self.uniquePreservingOrder([originalMonth, draft.month.rawValue]),
                transactions: [transactionID]
            )
        )
        await didUpdate()
        try await applyInvalidation(
            result.changed,
            budgetID: budgetID,
            newPayeeName: draft.payeeID == nil ? draft.payeeName : nil
        )
        return result
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void = {}
    ) async throws -> TransactionMutationResult {
        let client = try requireClient()
        _ = try await client.deleteTransaction(budgetID: budgetID, transaction: transaction)
        let result = TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [transaction.account],
                months: transaction.date.actualYearMonth.map { [$0] } ?? [],
                transactions: transaction.id.map { [$0] } ?? []
            )
        )
        await didDelete()
        try await applyInvalidation(result.changed, budgetID: budgetID)
        return result
    }

    func ensureAccounts(budgetID: String) async throws {
        if let entry = accountsByBudget[budgetID], Date().timeIntervalSince(entry.fetchedAt) < Self.referenceTTL {
            return
        }
        do {
            try await refreshAccounts(budgetID: budgetID)
        } catch {
            guard accountsByBudget[budgetID] != nil else {
                throw error
            }
        }
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

private extension ActualDataStore.CacheEntry where Value: Codable & Sendable {
    init(snapshot: ActualDataStoreSnapshot.SnapshotCacheEntry<Value>) {
        value = snapshot.value
        fetchedAt = snapshot.fetchedAt
    }
}

private extension ActualDataStoreSnapshot.SnapshotCacheEntry {
    init(_ cacheEntry: ActualDataStore.CacheEntry<Value>) {
        value = cacheEntry.value
        fetchedAt = cacheEntry.fetchedAt
    }
}
