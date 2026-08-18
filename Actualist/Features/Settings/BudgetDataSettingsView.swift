import SwiftUI

/// Budget & Data settings: selected budget, change budget, payees, encryption
/// status, reimport, default account, and account order.
struct BudgetDataSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var viewModel = SettingsViewModel()
    @State private var isBudgetPickerPresented = false
    @State private var isAccountOrderPresented = false
    @State private var isReimporting = false
    @State private var isReimportConfirmationPresented = false

    var body: some View {
        List {
            Section("Budget") {
                LabeledContent("Selected") {
                    Text(selectedBudgetDisplayName)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }

                LabeledContent("Security") {
                    Text(securityText)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }

                Button {
                    isBudgetPickerPresented = true
                } label: {
                    SettingsActionLabel(title: "Change Budget", systemImage: "folder")
                }

                NavigationLink {
                    PayeesView()
                } label: {
                    SettingsActionLabel(title: "Payees", systemImage: "person.2")
                }
                .disabled(appState.settings.selectedBudgetID == nil)
            }
            .settingsSectionChrome()

            Section {
                Button(role: .destructive) {
                    isReimportConfirmationPresented = true
                } label: {
                    SettingsActionLabel(
                        title: isReimporting ? "Reimporting" : "Reimport Budget",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(isReimporting || appState.settings.selectedBudgetID == nil)
            } header: {
                Text("Data")
            } footer: {
                Text("Deletes the local copy of this budget and downloads a fresh one from the server.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            Section("Accounts") {
                Button {
                    isAccountOrderPresented = true
                } label: {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(accountOrderDetail)
                                .foregroundStyle(ActualistTheme.secondaryText)
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(ActualistTheme.accent)
                        }
                    } label: {
                        Text("Account Order")
                            .foregroundStyle(ActualistTheme.primaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appState.settings.selectedBudgetID == nil)

                Menu {
                    Button {
                        appState.setDefaultAccountID(nil, budgetID: appState.settings.selectedBudgetID ?? "")
                    } label: {
                        if defaultAccountID == nil {
                            Label("First in Order", systemImage: "checkmark")
                        } else {
                            Text("First in Order")
                        }
                    }

                    ForEach(availableAccounts) { account in
                        Button {
                            appState.setDefaultAccountID(account.id, budgetID: appState.settings.selectedBudgetID ?? "")
                        } label: {
                            if defaultAccountID == account.id {
                                Label(account.name, systemImage: "checkmark")
                            } else {
                                Text(account.name)
                            }
                        }
                    }
                } label: {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(defaultAccountDetail)
                                .foregroundStyle(ActualistTheme.secondaryText)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    } label: {
                        Text("Default Account")
                            .foregroundStyle(ActualistTheme.primaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appState.settings.selectedBudgetID == nil || availableAccounts.isEmpty)
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Budget & Data")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.hydrate(from: appState)
        }
        .confirmationDialog(
            "Reimport Budget?",
            isPresented: $isReimportConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Reimport", role: .destructive) {
                Task { await reimport() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(reimportConfirmationMessage)
        }
        .sheet(isPresented: $isBudgetPickerPresented) {
            SettingsBudgetPickerSheet(
                viewModel: viewModel,
                isPresented: $isBudgetPickerPresented
            )
            .environment(appState)
        }
        .sheet(isPresented: $isAccountOrderPresented) {
            SettingsAccountOrderSheet()
                .environment(appState)
                .presentationDetents([.medium, .large])
                .appSwitcherPrivacyAwareDragIndicator()
        }
    }

    private var selectedBudgetDisplayName: String {
        PrivacyDisplay.selectedBudgetName(
            name: appState.settings.selectedBudgetName,
            id: appState.settings.selectedBudgetID,
            randomized: appState.settings.randomizedDisplayValuesEnabled
        )
    }

    private var securityText: String {
        if appState.localFirstSyncStatus?.encryptionKeyID != nil {
            return "Encrypted · Unlocked"
        }
        return "Not encrypted"
    }

    private var accountOrderDetail: String {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return "No Budget"
        }

        return appState.settings.accountOrderByBudgetID[budgetID] == nil ? "Actual Order" : "Custom"
    }

    private var defaultAccountID: String? {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return nil
        }
        return appState.defaultAccountID(forBudgetID: budgetID)
    }

    private var availableAccounts: [ActualAccount] {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return []
        }
        let accounts = appState.accountRepository
            .accountDisplays(budgetID: budgetID)
            .map(\.account)
            .filter { !$0.closed }
        return appState.orderedAccounts(accounts, budgetID: budgetID)
    }

    private var defaultAccountDetail: String {
        guard let id = defaultAccountID else {
            return "First in Order"
        }
        return availableAccounts.first(where: { $0.id == id })?.name ?? "First in Order"
    }

    private var reimportConfirmationMessage: String {
        let base = "Actualist will delete the local copy of this budget and download a fresh one from the server."
        let pendingCount = appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        guard pendingCount > 0 else {
            return "\(base) Your server data is not changed."
        }
        let noun = pendingCount == 1 ? "change" : "changes"
        return "\(base) Warning: \(pendingCount) local \(noun) have not been confirmed by the server and will be permanently lost."
    }

    private func reimport() async {
        guard !isReimporting else {
            return
        }
        isReimporting = true
        await appState.reimportLocalFirstBudget()
        isReimporting = false
    }
}
