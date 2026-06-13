import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var serverURLString = ""
    @State private var apiKey = ""
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    TextField("Server URL", text: $serverURLString, prompt: Text("http://host:5007"))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Text("Actualist adds /v1 when no path is provided.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)

                    Button {
                        Task { await saveAndTest() }
                    } label: {
                        Label(isTesting ? "Testing" : "Save and Test", systemImage: "network")
                    }
                }

                Section("Budget") {
                    LabeledContent("Selected") {
                        Text(appState.settings.selectedBudgetName ?? "None")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        appState.clearSelectionForBudgetChange()
                        Task { await appState.loadBudgets() }
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
                serverURLString = appState.settings.serverURLString
                apiKey = appState.apiKey
            }
        }
    }

    private func saveAndTest() async {
        isTesting = true
        appState.lastErrorMessage = nil
        appState.saveConnection(serverURLString: serverURLString, apiKey: apiKey)
        await appState.loadBudgets()
        isTesting = false
    }
}
