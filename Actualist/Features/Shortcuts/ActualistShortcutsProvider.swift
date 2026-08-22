import AppIntents
import Foundation

struct ActualistShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetAccountBalanceIntent(),
            phrases: [
                "Get \(\.$account) balance in \(.applicationName)"
            ],
            shortTitle: "Account Balance",
            systemImageName: "building.columns.fill"
        )
        AppShortcut(
            intent: GetCategoryBalanceIntent(),
            phrases: [
                "What's left in \(\.$category) in \(.applicationName)"
            ],
            shortTitle: "Category Balance",
            systemImageName: "list.bullet.rectangle.portrait.fill"
        )
        AppShortcut(
            intent: GetReadyToAssignIntent(),
            phrases: [
                "How much can I budget in \(.applicationName)"
            ],
            shortTitle: "Ready to Assign",
            systemImageName: "list.bullet.rectangle.portrait.fill"
        )
        AppShortcut(
            intent: LogTransactionIntent(),
            phrases: [
                "Log a transaction in \(.applicationName)"
            ],
            shortTitle: "Log Transaction",
            systemImageName: "plus"
        )
        AppShortcut(
            intent: OpenSpendingIntent(),
            phrases: [
                "Open spending in \(.applicationName)"
            ],
            shortTitle: "Open Spending",
            systemImageName: "creditcard.fill"
        )
        AppShortcut(
            intent: GetAccountsIntent(),
            phrases: [
                "Get accounts in \(.applicationName)"
            ],
            shortTitle: "Get Accounts",
            systemImageName: "building.columns.fill"
        )
    }
}
