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

extension LocalFirstActualStore {
    func fetchWidgetSource(budgetID: String, now: Date = Date()) async throws -> WidgetBudgetSource {
        let database = try requireDatabase(for: budgetID)
        let month = try await database.fetchBudgetMonth(month: WidgetMonthID.current(now: now))
        let currency = try await database.fetchBudgetCurrency()
        let accounts = try? await database.fetchAccountDisplays()
        let maps = try? await nameMaps(database)
        let recent = try? await database.fetchTransactionPage(limit: 16, splits: .grouped).transactions
        let netWorth = try? await database.fetchNetWorthReport(range: .dashboard(through: now))
        let attention: WidgetAttentionSnapshot?
        if let maps,
           let uncategorized = try? await database.fetchUncategorizedTransactions(),
           let tracking = try? await database.isTrackingBudget() {
            let count = uncategorized.filter {
                Self.isUncategorized($0, transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                                     offBudgetAccountIDs: maps.offBudgetAccountIDs)
            }.count
            let overspent = month.categoryGroups.filter { !$0.isIncome }.flatMap {
                BudgetCategoryVisibility.overspentCategories(in: $0, isTrackingBudget: tracking)
            }.filter { $0.balance < 0 }.map(\.id)
            attention = WidgetAttentionSnapshot(uncategorizedCount: count, overspentCategoryIDs: overspent)
        } else {
            attention = nil
        }
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
