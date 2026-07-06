import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = OnboardingViewModel()

    var body: some View {
        ZStack {
            ActualistTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Spacer(minLength: 42)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Actualist")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(ActualistTheme.primaryText)

                        Text("Connect to your Actual Budget server.")
                            .font(ActualistTypography.sectionTitle(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)

                        Text("Enter your Actual server credentials.")
                            .font(ActualistTypography.body(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText.opacity(0.82))
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 18) {
                            LabeledContent("Server URL") {
                                ZStack(alignment: .trailing) {
                                    if viewModel.serverURLString.isEmpty {
                                        Text("Required")
                                            .foregroundStyle(ActualistTheme.secondaryText)
                                    }

                                    TextField("", text: $viewModel.serverURLString)
                                        .textInputAutocapitalization(.never)
                                        .keyboardType(.URL)
                                        .multilineTextAlignment(.trailing)
                                }
                            }

                            Divider().overlay(ActualistTheme.separator)

                            LabeledContent("Password") {
                                SecureField(
                                    "",
                                    text: $viewModel.actualPassword,
                                    prompt: Text("Required").foregroundStyle(ActualistTheme.secondaryText)
                                )
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                            }
                        }
                        .foregroundStyle(ActualistTheme.primaryText)
                    }

                    if let warning = viewModel.connectionSecurityWarning {
                        Text(warning)
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.warning)
                    }

                    if let message = appState.lastErrorMessage {
                        Text(message)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                    }

                    Button {
                        Task { await viewModel.connect(using: appState) }
                    } label: {
                        HStack {
                            if viewModel.isConnecting {
                                ProgressView()
                            }
                            Text(viewModel.isConnecting ? "Connecting" : "Connect")
                                .font(ActualistTypography.control(for: density))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                    .disabled(!viewModel.canConnect)

                    Spacer(minLength: 120)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            viewModel.hydrate(from: appState)
        }
    }
}

struct BudgetPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = BudgetPickerViewModel()
    @State private var encryptedBudgetPrompt: ActualBudget?
    @State private var encryptionPassword = ""
    @State private var isUnlockingEncryptedBudget = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.budgets) { budget in
                        Button {
                            Task { await selectBudget(budget) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(budgetDisplayName(budget))
                                        .font(ActualistTypography.rowTitle(for: density))
                                    if !appState.settings.randomizedDisplayValuesEnabled {
                                        Text(budget.syncID)
                                            .font(ActualistTypography.rowLabel(for: density))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(ActualistTheme.secondaryText)
                            }
                        }
                    }
                } header: {
                    Text("Choose Budget")
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("Budgets")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.reload(using: appState) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .actualistToolbarGlassButton()
                }
            }
            .task {
                if appState.budgets.isEmpty {
                    await viewModel.reload(using: appState)
                }
            }
            .sheet(item: $encryptedBudgetPrompt) { budget in
                NavigationStack {
                    Form {
                        Section {
                            SecureField("Encryption Password", text: $encryptionPassword)
                                .textInputAutocapitalization(.never)
                        } footer: {
                            Text("This unlocks the selected encrypted Actual budget. Actualist stores the budget key in Keychain, not this password.")
                        }
                    }
                    .navigationTitle("Unlock Budget")
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
                            .disabled(encryptionPassword.isEmpty || isUnlockingEncryptedBudget)
                        }
                    }
                }
            }
        }
    }

    private func selectBudget(_ budget: ActualBudget) async {
        await appState.selectBudgetForCurrentBackend(budget)
        if appState.lastErrorMessage == LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription {
            encryptedBudgetPrompt = budget
        }
    }

    private func unlockBudget(_ budget: ActualBudget) async {
        isUnlockingEncryptedBudget = true
        await appState.selectBudgetForCurrentBackend(
            budget,
            encryptionPassword: encryptionPassword
        )
        isUnlockingEncryptedBudget = false
        if appState.lastErrorMessage != LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription {
            encryptedBudgetPrompt = nil
            encryptionPassword = ""
        }
    }

    private func budgetDisplayName(_ budget: ActualBudget) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return budget.name
        }

        return PrivacyDisplay.name(for: .budget, seed: budget.syncID)
    }
}
