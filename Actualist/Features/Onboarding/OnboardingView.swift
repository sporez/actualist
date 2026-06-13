import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var serverURLString = ""
    @State private var apiKey = ""
    @State private var isConnecting = false

    var body: some View {
        ZStack {
            ActualistTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Spacer(minLength: 42)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Actualist")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(ActualistTheme.primaryText)

                        Text("Connect to your Actual Budget server.")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(ActualistTheme.secondaryText)

                        Text("Enter the server base URL. Actualist adds /v1 when no path is provided.")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(ActualistTheme.secondaryText.opacity(0.82))
                    }

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 18) {
                            LabeledContent("Server URL") {
                                ZStack(alignment: .trailing) {
                                    if serverURLString.isEmpty {
                                        Text("Required")
                                            .foregroundStyle(ActualistTheme.secondaryText)
                                    }

                                    TextField("", text: $serverURLString)
                                        .textInputAutocapitalization(.never)
                                        .keyboardType(.URL)
                                        .multilineTextAlignment(.trailing)
                                }
                            }

                            Divider().overlay(ActualistTheme.separator)

                            LabeledContent("API Key") {
                                SecureField(
                                    "",
                                    text: $apiKey,
                                    prompt: Text("Required").foregroundStyle(ActualistTheme.secondaryText)
                                )
                                .textInputAutocapitalization(.never)
                                .multilineTextAlignment(.trailing)
                            }
                        }
                        .foregroundStyle(ActualistTheme.primaryText)
                    }

                    if let message = appState.lastErrorMessage {
                        Text(message)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(ActualistTheme.danger)
                    }

                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            if isConnecting {
                                ProgressView()
                            }
                            Text(isConnecting ? "Connecting" : "Connect")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(serverURLString.isEmpty || apiKey.isEmpty || isConnecting)

                    Spacer(minLength: 120)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            serverURLString = appState.settings.serverURLString
            apiKey = appState.apiKey
        }
    }

    private func connect() async {
        isConnecting = true
        appState.lastErrorMessage = nil
        appState.saveConnection(serverURLString: serverURLString, apiKey: apiKey)
        await appState.loadBudgets()
        isConnecting = false
    }
}

struct BudgetPickerView: View {
    @Environment(AppState.self) private var appState
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.budgets) { budget in
                        Button {
                            appState.selectBudget(budget)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(budget.name)
                                        .font(.headline)
                                    Text(budget.syncID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .actualistToolbarGlassButton()
                }
            }
            .task {
                if appState.budgets.isEmpty {
                    await reload()
                }
            }
        }
    }

    private func reload() async {
        isLoading = true
        await appState.loadBudgets()
        isLoading = false
    }
}
