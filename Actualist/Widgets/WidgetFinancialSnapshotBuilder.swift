import Foundation

enum WidgetFinancialSnapshotBuilder {
    static func make(
        source: WidgetBudgetSource, budgetID: String, budgetName: String,
        privacyEnabled: Bool, now: Date = Date()
    ) -> WidgetSnapshot {
        let currency = source.currency
        var snapshot = WidgetSnapshotBuilder.make(
            budgetID: budgetID, budgetName: budgetName, month: source.month,
            currency: currency, privacyEnabled: privacyEnabled, now: now
        )
        let month = BudgetMonthPrivacyProjection.displayMonth(
            source.month, isEnabled: privacyEnabled, currency: currency
        ) ?? source.month
        func money(_ value: Int) -> WidgetMoney {
            WidgetMoney(minorUnits: value, formatted: currency.formatted(value))
        }
        func amount(_ value: Int?, seed: String, maximum: Int = 25_000) -> WidgetMoney? {
            value.map {
                money(privacyEnabled
                    ? PrivacyDisplay.amount($0, seed: seed, currency: currency, maximumDollars: maximum)
                    : $0)
            }
        }
        snapshot.overview = WidgetMonthOverviewSnapshot(
            income: money(month.totalIncome), spent: money(-month.totalSpent),
            toBudget: money(month.toBudget), budgeted: money(month.totalBudgeted),
            available: money(month.totalBalance)
        )
        snapshot.accounts = source.accounts?.map { display in
            WidgetAccountSnapshot(
                id: display.id,
                name: privacyEnabled ? PrivacyDisplay.name(for: .account, seed: display.id) : display.account.name,
                group: display.account.offbudget ? "Off budget" : "On budget",
                isClosed: display.account.closed,
                balance: amount(display.balance, seed: "account-\(display.id)")
            )
        }
        snapshot.attention = source.attention.map { attention in
            // Counts follow the projected categories in sample-values mode.
            let overspent = privacyEnabled
                ? snapshot.categories.filter { $0.availableMinorUnits < 0 }.map(\.id)
                : attention.overspentCategoryIDs
            return WidgetAttentionSnapshot(
                uncategorizedCount: privacyEnabled ? (attention.uncategorizedCount == 0 ? 0 : 3) : attention.uncategorizedCount,
                overspentCategoryIDs: overspent
            )
        }
        let accountNames = Dictionary(uniqueKeysWithValues: (snapshot.accounts ?? []).map { ($0.id, $0.name) })
        snapshot.recentTransactions = source.recentTransactions?.compactMap { transaction in
            guard let id = transaction.id, !transaction.isChild else { return nil }
            let semantics = TransactionRowSemantics.project(
                transaction, lookup: source.transactionLookup, privacyEnabled: privacyEnabled
            )
            return WidgetTransactionSnapshot(
                id: id, accountID: transaction.account,
                accountName: accountNames[transaction.account] ?? "Account unavailable",
                payee: semantics.payeeText, date: transaction.date,
                amount: amount(transaction.amount, seed: "transaction-\(id)", maximum: 900)
            )
        }
        snapshot.netWorth = source.netWorth.map { report in
            let points = report.points.map { point in
                WidgetNetWorthPoint(
                    date: point.date,
                    amount: amount(point.value, seed: "reports-net-worth-\(point.dayID)", maximum: 250_000)!
                )
            }
            let balance = privacyEnabled ? (points.last?.amount ?? money(0)) : money(report.balance)
            let change = privacyEnabled
                ? balance.minorUnits - (points.first?.amount.minorUnits ?? balance.minorUnits)
                : report.change
            return WidgetNetWorthSnapshot(balance: balance, change: money(change), period: "6 months", points: points)
        }
        return snapshot
    }
}
