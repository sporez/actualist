import SwiftUI

enum AdaptiveRootDestination: Hashable {
    case budget
    case spending
    case reports
    case accounts
    case account(ActualAccount)
    case settings

    func title(privacyEnabled: Bool) -> String {
        switch self {
        case .budget: "Budget"
        case .spending: "Spending"
        case .reports: "Reports"
        case .accounts: "Accounts"
        case .account(let account):
            privacyEnabled ? PrivacyDisplay.name(for: .account, seed: account.id) : account.name
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .budget: AppTab.budget.symbolName
        case .spending: AppTab.spending.symbolName
        case .reports: AppTab.reports.symbolName
        case .accounts: AppTab.accounts.symbolName
        case .account: "building.columns"
        case .settings: "gearshape"
        }
    }
}

struct AdaptiveRootShell: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: AdaptiveRootDestination?
    @Bindable var viewport: BudgetViewportModel
    let budgetViewModel: BudgetViewModel
    let rootWidth: CGFloat

    @Environment(RootTransactionEditorPresenter.self) private var transactionPresenter
    @State private var isClosedAccountsExpanded = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
                .toolbar {
                    if selection?.isAccount != true && !(selection == .budget && viewport.selectedCategoryDetails != nil) {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                transactionPresenter.present()
                            } label: {
                                Label("Add Transaction", systemImage: "plus")
                            }
                            .accessibilityLabel("Add Transaction")
                            .keyboardShortcut("n", modifiers: [.command])
                        }
                    }
                }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        .environment(\.budgetCurrency, displayedBudgetCurrency)
        .environment(\.budgetSidebarLayoutActive, true)
        .environment(\.budgetRootWidth, rootWidth)
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.requiresReauthentication { RootReauthenticationBanner() }
        }
        .onAppear {
            synchronizeSelection(preservingSettings: true)
            consumeShortcutRoute()
        }
        .onChange(of: appState.selectedTab) { _, _ in synchronizeSelection() }
        .onChange(of: selection) { _, newSelection in
            guard let newSelection else { return }
            switch newSelection {
            case .budget: appState.selectedTab = .budget
            case .spending: appState.selectedTab = .spending
            case .reports: appState.selectedTab = .reports
            case .accounts: appState.selectedTab = .accounts
            case .account(let account):
                appState.selectedTab = .accounts
                appState.accountNavigationPath = [account]
            case .settings: break
            }
        }
        .onChange(of: appState.routeCoordinator.pendingRoute) { consumeShortcutRoute() }

    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                destinationRow(.budget)
                destinationRow(.spending)
                destinationRow(.reports)
            }

            Section("Accounts") {
                destinationRow(.accounts)
                ForEach(openAccountDisplays) { display in
                    destinationRow(.account(display.account))
                }
                if !closedAccountDisplays.isEmpty {
                    DisclosureGroup("Closed", isExpanded: $isClosedAccountsExpanded) {
                        ForEach(closedAccountDisplays) { display in
                            destinationRow(.account(display.account))
                        }
                    }
                }
            }

            Section {
                destinationRow(.settings)
            }
        }
        .tint(ActualistTheme.accent)
        .navigationTitle("Actualist")
    }

    @ViewBuilder
    private func destinationRow(_ destination: AdaptiveRootDestination) -> some View {
        Label(destination.title(privacyEnabled: appState.settings.randomizedDisplayValuesEnabled), systemImage: destination.symbolName)
            .tag(destination)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .budget {
        case .budget:
            BudgetWorkspaceView(viewport: viewport, compactModel: budgetViewModel)
        case .spending:
            SpendingTransactionsView()
        case .reports:
            ReportsView()
        case .accounts:
            AccountsView()
        case .account(let account):
            NavigationStack {
                AccountTransactionsView(account: account)
            }
        case .settings:
            SettingsView()
        }
    }

    private var accountDisplays: [AccountDisplay] {
        guard let budgetID = appState.settings.selectedBudgetID else { return [] }
        return appState.accountRepository.accountDisplays(budgetID: budgetID)
    }

    private var openAccountDisplays: [AccountDisplay] {
        accountDisplays.filter { !$0.account.closed }
    }

    private var closedAccountDisplays: [AccountDisplay] {
        accountDisplays.filter(\.account.closed)
    }

    private var displayedBudgetCurrency: BudgetCurrency {
        guard let budgetID = appState.settings.selectedBudgetID else { return .usd }
        return appState.localFirstStore.budgetCurrency(budgetID: budgetID)
    }

    private func synchronizeSelection(preservingSettings: Bool = false) {
        selection = AdaptiveRootTransition.selection(
            for: .sidebar,
            appTab: appState.selectedTab,
            preserving: selection == .settings && !preservingSettings ? nil : selection
        )
    }

    private func consumeShortcutRoute() {
        guard let route = appState.routeCoordinator.pendingRoute else { return }
        switch route {
        case .tab(let tab):
            selection = AdaptiveRootDestination(tab: tab)
            _ = appState.routeCoordinator.consume()
        case .account(let id):
            if let account = accountDisplays.map(\.account).first(where: { $0.id == id }) {
                selection = .account(account)
                _ = appState.routeCoordinator.consume()
            }
        case .newTransaction:
            _ = transactionPresenter.consumeNewTransaction(from: appState.routeCoordinator)
        case .settings:
            selection = .settings
            _ = appState.routeCoordinator.consume()
        default:
            break
        }
    }

}

extension AdaptiveRootDestination {
    var isAccount: Bool {
        if case .account = self { return true }
        return false
    }

    init(tab: AppTab) {
        switch tab {
        case .budget: self = .budget
        case .spending: self = .spending
        case .accounts: self = .accounts
        case .reports: self = .reports
        }
    }

    var appTab: AppTab? {
        switch self {
        case .budget: .budget
        case .spending: .spending
        case .reports: .reports
        case .accounts, .account: .accounts
        case .settings: nil
        }
    }
}
