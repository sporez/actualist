import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    let budgetViewModel: BudgetViewModel
    @Environment(RootTransactionEditorPresenter.self) private var transactionPresenter

    init(budgetViewModel: BudgetViewModel) {
        self.budgetViewModel = budgetViewModel
    }

    var body: some View {
        TabView(selection: selectedTab) {
            BudgetView(viewModel: budgetViewModel, loadsOnAppear: false)
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
        // The width-selected compact shell keeps native tabs at the bottom on iPad.
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.budgetCurrency, displayedBudgetCurrency)
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.requiresReauthentication {
                RootReauthenticationBanner()
            }
        }
        .onAppear(perform: consumeShortcutRoute)
        .onChange(of: appState.routeCoordinator.pendingRoute) {
            consumeShortcutRoute()
        }

    }

    private var displayedBudgetCurrency: BudgetCurrency {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return .usd
        }
        return appState.localFirstStore.budgetCurrency(budgetID: budgetID)
    }

    private func consumeShortcutRoute() {
        _ = appState.routeCoordinator.consume {
            if case .tab = $0 { return true }
            return false
        }
        _ = transactionPresenter.consumeNewTransaction(using: appState)
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
