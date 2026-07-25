import SwiftUI

struct SettingsAccountOrderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss

    @State private var accounts: [ActualAccount] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView("Loading accounts")
                        .settingsRowChrome()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.danger)
                        .settingsRowChrome()
                }

                Section("Accounts") {
                    if appState.settings.selectedBudgetID == nil {
                        Text("Select a budget before setting account order.")
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } else if accounts.isEmpty && !isLoading {
                        Text("No accounts loaded.")
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } else {
                        ForEach(accounts) { account in
                            SettingsAccountOrderRow(account: account)
                        }
                        .onMove(perform: moveAccounts)
                    }
                }
                .settingsSectionChrome()
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Account Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        resetOrder()
                    }
                    .disabled(!hasCustomOrder)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadAccounts()
            }
            .refreshable {
                await refreshAccounts()
            }
        }
    }

    private var hasCustomOrder: Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        return appState.settings.accountOrderByBudgetID[budgetID] != nil
    }

    private func loadAccounts() async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            accounts = []
            errorMessage = nil
            return
        }

        let cachedAccounts = appState.makeAccountRepository()?.accountDisplays(budgetID: budgetID).map(\.account) ?? []
        accounts = appState.orderedAccounts(cachedAccounts, budgetID: budgetID)
        isLoading = accounts.isEmpty
        errorMessage = nil
        do {
            guard let repository = appState.makeAccountRepository() else {
                accounts = []
                isLoading = false
                return
            }
            try await repository.refreshAccountsWithBalances(budgetID: budgetID)
        } catch {
            errorMessage = appState.makeAccountRepository()?.accountDisplays(budgetID: budgetID).isEmpty == false
                ? "Could not refresh accounts. Showing cached accounts."
                : error.localizedDescription
        }

        let loadedAccounts = appState.makeAccountRepository()?.accountDisplays(budgetID: budgetID).map(\.account) ?? []
        accounts = appState.orderedAccounts(loadedAccounts, budgetID: budgetID)
        isLoading = false
    }

    private func refreshAccounts() async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        await loadAccounts()
    }

    private func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        persistOrder()
    }

    private func persistOrder() {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }

        appState.updateAccountOrder(accounts.map(\.id), budgetID: budgetID)
    }

    private func resetOrder() {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }

        appState.resetAccountOrder(budgetID: budgetID)
        accounts = appState.makeAccountRepository()?.accountDisplays(budgetID: budgetID).map(\.account) ?? accounts
    }
}

private struct SettingsAccountOrderRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density

    let account: ActualAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.offbudget ? "tray.full.fill" : "banknote.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.accent)
                .frame(width: density.iconSize, height: density.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                if let detail {
                    Text(detail)
                        .font(ActualistTypography.rowLabel(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return account.name
        }

        return PrivacyDisplay.name(for: .account, seed: account.id)
    }

    private var detail: String? {
        if account.closed {
            return "Closed"
        }
        if account.offbudget {
            return "Off Budget"
        }
        return nil
    }
}

