import SwiftUI

struct SettingsBudgetPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: SettingsViewModel
    @Binding var isPresented: Bool
    @State private var emptyBudgetCoordinator = EmptyBudgetPickerCoordinator()

    var body: some View {
        List {
            ReviewSheetListHeader(title: "Budgets")
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

            if !appState.budgets.isEmpty {
                Section {
                    ForEach(appState.budgets) { budget in
                        Button {
                            Task {
                                if await viewModel.selectBudget(budget, using: appState) {
                                    isPresented = false
                                }
                            }
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
                        .disabled(appState.budgetSessionTransitions.isTransitionInFlight)
                    }
                } header: {
                    Text("Choose Budget")
                } footer: {
                    SampleValuesPickerFooter()
                }
                .settingsSectionChrome()
            }

            if emptyBudgetCoordinator.offer(using: appState) == .offered {
                EmptyBudgetPickerSection(coordinator: emptyBudgetCoordinator)
                .settingsSectionChrome()
            }
        }
        .reviewSheetList()
        .emptyBudgetPickerPresentations(
            coordinator: emptyBudgetCoordinator,
            onBudgetSelected: { isPresented = false }
        )
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton { dismiss() }
        }
        .task {
            // Demo mode has a single bundled budget and no server list to load.
            guard !appState.isDemoMode else {
                return
            }
            let succeeded = await viewModel.loadBudgetsForSelection(using: appState)
            emptyBudgetCoordinator.recordDiscovery(succeeded: succeeded)
        }
        .sheet(item: $viewModel.encryptedBudgetPrompt, onDismiss: viewModel.dismissEncryptedBudgetPrompt) { budget in
            EncryptedBudgetUnlockSheet(
                encryptionPassword: $viewModel.encryptionPassword,
                isUnlocking: viewModel.isUnlockingEncryptedBudget,
                errorMessage: appState.lastErrorMessage,
                onCancel: viewModel.dismissEncryptedBudgetPrompt,
                onUnlock: {
                    Task {
                        if await viewModel.unlockEncryptedBudget(budget, using: appState) {
                            isPresented = false
                        }
                    }
                }
            )
            .environment(appState)
        }
        .reviewSheetPresentation(appState: appState)
    }

    private func budgetDisplayName(_ budget: ActualBudget) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return budget.name
        }

        return PrivacyDisplay.name(for: .budget, seed: budget.syncID)
    }
}
