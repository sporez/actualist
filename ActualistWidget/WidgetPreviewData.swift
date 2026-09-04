import Foundation

/// Synthetic gallery and preview content; no budget data is embedded in the extension.
enum WidgetPreviewData {
    static var snapshot: WidgetSnapshot {
        let now = Date()
        func money(_ amount: Int) -> WidgetMoney {
            WidgetMoney(minorUnits: amount, formatted: String(format: "$%.2f", Double(amount) / 100))
        }
        let names = ["Groceries", "Dining", "Transport", "Utilities", "Travel", "Home", "Gifts", "Health", "Shopping", "Savings", "Fuel", "Subscriptions", "Pets", "Insurance", "Education", "Fun"]
        let accounts = ["Checking", "Savings", "Credit Card", "Cash", "Brokerage", "Travel Card", "Reserve", "Joint Checking"]
        var value = WidgetSnapshot(
            schemaVersion: WidgetSnapshot.currentSchemaVersion, budgetID: "preview", budgetName: "Sample Budget",
            month: WidgetMonthID.current(now: now), privacyEnabled: true, updatedAt: now,
            categories: names.enumerated().map { index, name in
                let amount = index == 1 ? -2500 : (index + 1) * 12500
                return WidgetCategorySnapshot(id: "category-\(index)", displayName: name, group: "Everyday", isHidden: false,
                    availableMinorUnits: amount, formattedAvailable: money(amount).formatted)
            }
        )
        value.accounts = accounts.enumerated().map { index, name in
            WidgetAccountSnapshot(id: "account-\(index)", name: name, group: "On budget", isClosed: false,
                balance: money(index == 2 ? -42500 : (index + 1) * 170000))
        }
        value.attention = WidgetAttentionSnapshot(uncategorizedCount: 7, overspentCategoryIDs: ["category-1"])
        value.overview = WidgetMonthOverviewSnapshot(income: money(450000), spent: money(182450), toBudget: money(60000), budgeted: money(390000), available: money(267550))
        value.recentTransactions = (0..<16).map { index in
            WidgetTransactionSnapshot(id: "transaction-\(index)", accountID: "account-0", accountName: "Checking",
                payee: ["Market", "Cafe", "Bookstore", "Transit"][index % 4], date: "Sep \(max(1, 20 - index))", amount: money(-(index + 1) * 825))
        }
        let points = (0..<24).map { index in
            WidgetNetWorthPoint(date: now.addingTimeInterval(Double(index - 23) * 7 * 86400), amount: money(1_200_000 + index * 20_000))
        }
        value.netWorth = WidgetNetWorthSnapshot(balance: points.last!.amount, change: money(460000), period: "6 months", points: points)
        return value
    }
}
