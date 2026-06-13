import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    TextField("Server URL", text: $viewModel.serverURLString, prompt: Text("http://host:5007"))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Text("Actualist adds /v1 when no path is provided.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    SecureField("API Key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)

                    Button {
                        Task { await viewModel.saveAndTest(using: appState) }
                    } label: {
                        Label(viewModel.isTesting ? "Testing" : "Save and Test", systemImage: "network")
                    }
                }

                Section("Budget") {
                    LabeledContent("Selected") {
                        Text(appState.settings.selectedBudgetName ?? "None")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await viewModel.changeBudget(using: appState) }
                    } label: {
                        Label("Change Budget", systemImage: "folder")
                    }
                }

                Section("Appearance") {
                    LabeledContent("Theme") {
                        Text("Reference Dark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("Settings")
            .onAppear {
                viewModel.hydrate(from: appState)
            }
        }
    }
}
