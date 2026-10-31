import Foundation

/// Synthetic gallery and preview content; no budget data is embedded in the extension.
enum WidgetPreviewData {
    static var snapshot: WidgetSnapshot {
        let now = Date()
        func money(_ amount: Int) -> WidgetMoney {
            WidgetMoney(minorUnits: amount, formatted: (Double(amount) / 100).formatted(.currency(code: "USD")))
        }
        let names = ["Groceries", "Dining", "Transport", "Utilities", "Travel", "Home", "Gifts", "Health", "Shopping", "Savings", "Fuel", "Subscriptions", "Pets", "Insurance", "Education", "Fun"]
        let accounts = ["Checking", "Savings", "Credit Card", "Cash", "Brokerage", "Travel Card", "Reserve", "Joint Checking"]
        var value = WidgetSnapshot(
            schemaVersion: WidgetSnapshot.currentSchemaVersion, budgetID: "preview", budgetName: "Sample Budget",
            month: WidgetMonthID.current(now: now), privacyEnabled: true, updatedAt: now,
            categories: names.enumerated().map { index, name in
                let amount = index == 1 ? -2500 : (index == 4 ? -8200 : (index + 1) * 12500)
                return WidgetCategorySnapshot(id: "category-\(index)", displayName: name, group: "Everyday", isHidden: false,
                    availableMinorUnits: amount, formattedAvailable: money(amount).formatted)
            }
        )
        value.accounts = accounts.enumerated().map { index, name in
            WidgetAccountSnapshot(id: "account-\(index)", name: name, group: "On budget", isClosed: false,
                balance: money(index == 2 ? -42500 : (index + 1) * 170000))
        }
        value.attention = WidgetAttentionSnapshot(uncategorizedCount: 4, overspentCategoryIDs: ["category-1", "category-4"])
        value.overview = WidgetMonthOverviewSnapshot(income: money(450000), spent: money(182450), toBudget: money(60000), budgeted: money(390000), available: money(267550))
        let calendar = WidgetMonthID.gregorianCalendar()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        value.recentTransactions = (0..<16).map { index in
            let day = calendar.date(byAdding: .day, value: -index / 2, to: now) ?? now
            let isIncome = index % 7 == 3
            return WidgetTransactionSnapshot(id: "transaction-\(index)", accountID: "account-0", accountName: index % 3 == 0 ? "Credit Card" : "Checking",
                payee: isIncome ? "Payroll" : ["Market", "Cafe", "Bookstore", "Transit"][index % 4], date: formatter.string(from: day),
                amount: money(isIncome ? 240000 : -(index + 1) * 825))
        }
        let swings = [0, 90_000, 40_000, 160_000, 130_000, 260_000, 230_000, 380_000, 460_000]
        let points = swings.enumerated().map { index, swing in
            WidgetNetWorthPoint(date: now.addingTimeInterval(Double(index - 8) * 21 * 86400), amount: money(1_200_000 + swing))
        }
        value.netWorth = WidgetNetWorthSnapshot(balance: points.last!.amount, change: money(460000), period: "6 months", points: points)
        return value
    }
}
