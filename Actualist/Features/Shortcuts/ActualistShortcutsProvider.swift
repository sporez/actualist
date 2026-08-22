import AppIntents
import Foundation

struct ActualistShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
