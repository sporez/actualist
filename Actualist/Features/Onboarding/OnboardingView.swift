import AuthenticationServices
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
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

                        Text("Enter your server first. Actualist will use its sign-in setup and guide you through the next step.")
                            .font(ActualistTypography.body(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText.opacity(0.82))
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Server URL")
                                    .font(ActualistTypography.rowLabel(for: density))
                                    .foregroundStyle(ActualistTheme.secondaryText)

                                TextField(
                                    "Server URL",
                                    text: $viewModel.serverURLString,
                                    prompt: Text("https://actual.example.com")
                                        .foregroundStyle(ActualistTheme.secondaryText)
                                )
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.primaryText)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .multilineTextAlignment(.leading)
                                .accessibilityLabel("Server URL")
                            }

                        }
                    }

                    if viewModel.showsPasswordForm {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Server Password")
                                    .font(ActualistTypography.rowLabel(for: density))
                                    .foregroundStyle(ActualistTheme.secondaryText)

                                SecureField(
                                    "Password",
                                    text: $viewModel.actualPassword,
                                    prompt: Text("Required").foregroundStyle(ActualistTheme.secondaryText)
                                )
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.primaryText)
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.leading)
                                .accessibilityLabel("Server Password")
                            }
                        }
                    }

                    if let message = viewModel.unsupportedAuthenticationMessage {
                        Text(message)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.warning)
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

                    if !viewModel.hasLoadedLoginMethods {
                        Button {
                            Task {
                                await viewModel.continueFromServer(using: appState) { authorizationURL in
                                    try await authenticate(using: authorizationURL)
                                }
                            }
                        } label: {
                            HStack {
                                if viewModel.isLoadingLoginMethods {
                                    ProgressView()
                                }
                                Text(viewModel.isLoadingLoginMethods ? "Checking Server" : "Continue")
                                    .font(ActualistTypography.control(for: density))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(ActualistTheme.accent)
                        .disabled(!viewModel.canLoadLoginMethods)
                    }

                    if viewModel.showsOpenIDAction {
                        Button {
                            Task {
                                await viewModel.connectWithOpenID(using: appState) { authorizationURL in
                                    try await authenticate(using: authorizationURL)
                                }
                            }
                        } label: {
                            HStack {
                                if viewModel.isConnecting {
                                    ProgressView()
                                }
                                Text(viewModel.isConnecting ? "Signing In" : "Continue with OpenID")
                                    .font(ActualistTypography.control(for: density))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(ActualistTheme.accent)
                        .disabled(viewModel.isConnecting)
                    }

                    if viewModel.showsPasswordForm {
                        Button {
                            Task { await viewModel.connectWithPassword(using: appState) }
                        } label: {
                            HStack {
                                if viewModel.isConnecting {
                                    ProgressView()
                                }
                                Text(viewModel.isConnecting ? "Connecting" : "Connect with Password")
                                    .font(ActualistTypography.control(for: density))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(ActualistTheme.accent)
                        .disabled(!viewModel.canConnectWithPassword)
                    }

                    if viewModel.hasLoadedLoginMethods && viewModel.supportsPassword && viewModel.supportsOpenID {
                        Button {
                            viewModel.isUsingPassword.toggle()
                            appState.lastErrorMessage = nil
                        } label: {
                            Text(viewModel.isUsingPassword ? "Use OpenID instead" : "Use server password")
                                .font(ActualistTypography.control(for: density))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .disabled(viewModel.isConnecting)
                    }

                    if appState.canCancelReauthentication {
                        Button {
                            appState.cancelReauthentication()
                        } label: {
                            Text("Cancel")
                                .font(ActualistTypography.control(for: density))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .disabled(viewModel.isConnecting || viewModel.isLoadingLoginMethods)
                    }

                    Spacer(minLength: 120)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            viewModel.hydrate(from: appState)
        }
        .onChange(of: viewModel.serverURLString) { _, _ in
            if viewModel.hasLoadedLoginMethods {
                viewModel.serverURLDidChange()
            }
        }
    }

    private func authenticate(using authorizationURL: URL) async throws -> URL {
        try await webAuthenticationSession.authenticate(
            using: authorizationURL,
            callback: .customScheme(ActualOpenIDAuthenticationCoordinator.callbackScheme),
            preferredBrowserSession: nil,
            additionalHeaderFields: [:]
        )
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
            .task {
                if appState.budgets.isEmpty {
                    await viewModel.reload(using: appState)
                }
            }
            .refreshable {
                await viewModel.reload(using: appState)
            }
            .sheet(item: $encryptedBudgetPrompt, onDismiss: clearEncryptedBudgetPassword) { budget in
                EncryptedBudgetUnlockSheet(
                    encryptionPassword: $encryptionPassword,
                    isUnlocking: isUnlockingEncryptedBudget,
                    errorMessage: encryptedBudgetUnlockErrorMessage,
                    onCancel: {
                        encryptedBudgetPrompt = nil
                        clearEncryptedBudgetPassword()
                    },
                    onUnlock: {
                        Task { await unlockBudget(budget) }
                    }
                )
            }
        }
    }

    private var encryptedBudgetUnlockErrorMessage: String? {
        guard let message = appState.lastErrorMessage,
              message != LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription else {
            return nil
        }
        return message
    }

    private func clearEncryptedBudgetPassword() {
        encryptionPassword = ""
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
