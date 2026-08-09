import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView(selection: selectedTab) {
            BudgetView(initialMonth: appState.cachedSelectedBudgetMonth)
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

            ReportsView()
                .tabItem {
                    Label(AppTab.reports.title, systemImage: AppTab.reports.symbolName)
                }
                .tag(AppTab.reports)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.requiresReauthentication {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(ActualistTheme.warning)
                    Text("Your Actual session expired. Sign in again to resume syncing.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ActualistTheme.primaryText)
                    Spacer(minLength: 8)
                    Button("Sign In Again") {
                        appState.beginReauthentication()
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(ActualistTheme.background)
            }
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
