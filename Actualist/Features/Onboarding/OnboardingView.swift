import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = OnboardingViewModel()

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

                            LabeledContent("API Key") {
                                SecureField(
                                    "",
                                    text: $viewModel.apiKey,
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
                        Task { await viewModel.connect(using: appState) }
                    } label: {
                        HStack {
                            if viewModel.isConnecting {
                                ProgressView()
                            }
                            Text(viewModel.isConnecting ? "Connecting" : "Connect")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(viewModel.serverURLString.isEmpty || viewModel.apiKey.isEmpty || viewModel.isConnecting)

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
    @State private var viewModel = BudgetPickerViewModel()

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
        }
    }
}
