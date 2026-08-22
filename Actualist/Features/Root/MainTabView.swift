import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var editorPrefill: ShortcutEditorPrefill?
    @State private var isShortcutEditorPresented = false

    var body: some View {
        TabView(selection: selectedTab) {
            BudgetView(
                initialMonth: appState.cachedSelectedBudgetMonth,
                initialBudgetID: appState.settings.selectedBudgetID
            )
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
                    .tint(ActualistTheme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(ActualistTheme.background)
            }
        }
        .onAppear(perform: consumeShortcutRoute)
        .onChange(of: appState.routeCoordinator.pendingRoute) {
            consumeShortcutRoute()
        }
        .sheet(isPresented: $isShortcutEditorPresented) {
            TransactionEditorView(
                prefilledAccount: prefilledAccount,
                prefilledPayeeName: editorPrefill?.payeeName,
                prefilledCategoryName: editorPrefill?.categoryName,
                shortcutPrefill: editorPrefill
            )
            .environment(appState)
            .appSwitcherPrivacyProtected()
        }
    }

    private var prefilledAccount: ActualAccount? {
        guard let accountID = editorPrefill?.accountID,
              let budgetID = appState.settings.selectedBudgetID else {
            return nil
        }
        return appState.accountRepository.accountDisplays(budgetID: budgetID)
            .map(\.account)
            .first { $0.id == accountID }
    }

    private func consumeShortcutRoute() {
        _ = appState.routeCoordinator.consume {
            if case .tab = $0 { return true }
            if case .account = $0 { return true }
            return false
        }
        guard case .newTransaction(let prefill) = appState.routeCoordinator.consume(if: {
            if case .newTransaction = $0 { return true }
            return false
        }) else {
            return
        }
        editorPrefill = prefill
        isShortcutEditorPresented = true
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
