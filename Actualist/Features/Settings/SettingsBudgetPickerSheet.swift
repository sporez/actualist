import SwiftUI

struct SettingsBudgetPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: SettingsViewModel
    @Binding var isPresented: Bool
    @State private var encryptedBudgetPrompt: ActualBudget?
    @State private var encryptionPassword = ""
    @State private var isUnlockingEncryptedBudget = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isLoadingBudgets {
                    ProgressView("Loading budgets")
                        .settingsRowChrome()
                }

                if let message = appState.lastErrorMessage {
                    Text(message)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.danger)
                        .settingsRowChrome()
                }

                Section("Choose Budget") {
                    ForEach(appState.budgets) { budget in
                        Button {
                            Task { await selectBudget(budget) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(budgetDisplayName(budget))
                                        .font(ActualistTypography.rowTitle(for: density))
                                        .foregroundStyle(ActualistTheme.primaryText)
                                    if !appState.settings.randomizedDisplayValuesEnabled {
                                        Text(budget.syncID)
                                            .font(ActualistTypography.rowLabel(for: density))
                                            .foregroundStyle(ActualistTheme.secondaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }

                                Spacer()

                                if appState.settings.selectedBudgetID == budget.syncID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(ActualistTheme.accent)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(ActualistTheme.secondaryText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Budgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await viewModel.loadBudgetsForSelection(using: appState)
            }
            .refreshable {
                await viewModel.loadBudgetsForSelection(using: appState)
            }
            .sheet(item: $encryptedBudgetPrompt) { budget in
                NavigationStack {
                    Form {
                        Section {
                            SecureField("Encryption Password", text: $encryptionPassword)
                                .textInputAutocapitalization(.never)
                                .textContentType(.password)
                        } footer: {
                            Text(LocalFirstRecoveryGuidance.encryptionPasswordNotice)
                        }

                        if let message = appState.lastErrorMessage,
                           message != LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription {
                            Section {
                                Text(message)
                                    .font(ActualistTypography.rowTitle(for: density))
                                    .foregroundStyle(ActualistTheme.danger)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(ActualistTheme.background)
                    .foregroundStyle(ActualistTheme.primaryText)
                    .tint(ActualistTheme.accent)
                    .navigationTitle("Unlock Budget")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                encryptedBudgetPrompt = nil
                                encryptionPassword = ""
                            }
                        }

                        ToolbarItem(placement: .confirmationAction) {
                            Button(isUnlockingEncryptedBudget ? "Unlocking" : "Unlock") {
                                Task { await unlockBudget(budget) }
                            }
                            .disabled(encryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUnlockingEncryptedBudget)
                        }
                    }
                }
                .presentationDetents([.medium])
                .appSwitcherPrivacyAwareDragIndicator()
                .appSwitcherPrivacyProtected()
            }
        }
        .appSwitcherPrivacyProtected()
    }

    private func selectBudget(_ budget: ActualBudget) async {
        await appState.selectBudgetForCurrentBackend(budget)
        if appState.lastErrorMessage == LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription {
            encryptedBudgetPrompt = budget
            return
        }

        if appState.settings.selectedBudgetID == budget.syncID {
            isPresented = false
        }
    }

    private func unlockBudget(_ budget: ActualBudget) async {
        guard !isUnlockingEncryptedBudget else {
            return
        }

        isUnlockingEncryptedBudget = true
        await appState.selectBudgetForCurrentBackend(
            budget,
            encryptionPassword: encryptionPassword
        )
        isUnlockingEncryptedBudget = false

        if appState.settings.selectedBudgetID == budget.syncID {
            encryptedBudgetPrompt = nil
            encryptionPassword = ""
            isPresented = false
        }
    }

    private func budgetDisplayName(_ budget: ActualBudget) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return budget.name
        }

        return PrivacyDisplay.name(for: .budget, seed: budget.syncID)
    }
}
