import Foundation

/// One publication read. It never replaces a screen's selected month or feed.
struct WidgetBudgetSource: Sendable {
    let month: BudgetMonth
    let currency: BudgetCurrency
    let accounts: [AccountDisplay]?
    let attention: WidgetAttentionSnapshot?
    let recentTransactions: [ActualTransaction]?
    let transactionLookup: TransactionRowLookup
    let netWorth: NetWorthReport?
}

/// The widget snapshot read on the store: one publication read of the
/// current month, accounts, attention counts, recent transactions and net
/// worth. The store owns it.
@MainActor
final class WidgetSourceWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func fetchWidgetSource(budgetID: String, now: Date = Date()) async throws -> WidgetBudgetSource {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetReadGeneration
        let financial = try await BudgetMonthSQL.fetchBudgetSnapshot(month: WidgetMonthID.current(now: now), in: database)
        let month = financial.month
        let currency = financial.currency
        let accounts = try? await AccountSQL.fetchAccountDisplays(in: database)
        let maps = try? await store.nameMaps(database)
        let recent = try? await TransactionReadSQL.fetchTransactionPage(limit: 16, splits: .grouped, in: database).transactions
        let netWorth = try? await ReportDashboardSQL.fetchNetWorthReport(range: .dashboard(through: now), in: database)
        let attention: WidgetAttentionSnapshot?
        if let maps,
           let uncategorized = try? await TransactionReadSQL.fetchUncategorizedTransactions(in: database) {
            let count = uncategorized.filter {
                LocalFirstActualStore.isUncategorized($0, transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                                     offBudgetAccountIDs: maps.offBudgetAccountIDs)
            }.count
            let overspent = month.categoryGroups.filter { !$0.isIncome }.flatMap {
                BudgetCategoryVisibility.overspentCategories(in: $0, isTrackingBudget: month.trackingSummary != nil)
            }.filter { $0.balance < 0 }.map(\.id)
            attention = WidgetAttentionSnapshot(uncategorizedCount: count, overspentCategoryIDs: overspent)
        } else {
            attention = nil
        }
        let currentIdentity = try await BudgetModeSQL.fetchBudgetModeIdentity(in: database)
        guard store.database === database, store.openedBudgetID == budgetID,
              store.budgetReadGeneration == generation, financial.modeIdentity == currentIdentity else { throw CancellationError() }
        return WidgetBudgetSource(
            month: month, currency: currency, accounts: accounts, attention: attention,
            recentTransactions: maps == nil || accounts == nil ? nil : recent,
            transactionLookup: TransactionRowLookup(
                payeeNames: maps?.payeeNames ?? [:], categoryNames: maps?.categoryNames ?? [:],
                transferPayeeIDs: maps?.transferPayeeIDs ?? [],
                transferAccountIDsByPayeeID: maps?.transferAccountIDsByPayeeID ?? [:],
                offBudgetAccountIDs: maps?.offBudgetAccountIDs ?? []
            ),
            netWorth: netWorth
        )
    }
}
