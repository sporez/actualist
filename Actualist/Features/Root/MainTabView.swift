import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView(selection: selectedTab) {
            BudgetView()
                .tabItem {
                    Label(AppTab.budget.title, systemImage: AppTab.budget.symbolName)
                }
                .tag(AppTab.budget)

            SpendingTransactionsView()
                .tabItem {
                    Label(AppTab.spending.title, systemImage: AppTab.spending.symbolName)
                }
                .tag(AppTab.spending)

            AccountsView()
                .tabItem {
                    Label(AppTab.accounts.title, systemImage: AppTab.accounts.symbolName)
                }
                .tag(AppTab.accounts)

            SettingsView()
                .tabItem {
                    Label(AppTab.settings.title, systemImage: AppTab.settings.symbolName)
                }
                .tag(AppTab.settings)
        }
    }

    private var selectedTab: Binding<AppTab> {
        Binding {
            appState.selectedTab
        } set: { newValue in
            withAnimation(.smooth(duration: 0.2)) {
                appState.selectedTab = newValue
            }
        }
    }
}
