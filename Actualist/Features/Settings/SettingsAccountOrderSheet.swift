import SwiftUI

struct SettingsAccountOrderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss

    @State private var model = SettingsAccountOrderViewModel()

    private var accounts: [ActualAccount] { model.accounts(using: appState) }

    var body: some View {
        NavigationStack {
            List {
                if model.isLoading {
                    ProgressView("Loading accounts")
                        .settingsRowChrome()
                }

                if let errorMessage = model.errorMessage {
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
                    } else if accounts.isEmpty && !model.isLoading {
                        Text("No accounts loaded.")
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } else {
                        ForEach(accounts) { account in
                            SettingsAccountOrderRow(account: account)
                        }
                        .onMove { model.move(from: $0, to: $1, using: appState) }
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
                        model.reset(using: appState)
                    }
                    .disabled(!model.hasCustomOrder(using: appState))
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await model.load(using: appState)
            }
            .refreshable {
                await model.refresh(using: appState)
            }
        }
        .appSwitcherPrivacyProtected(using: appState)
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
