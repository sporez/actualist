import SwiftUI

/// Connection & Sync settings: server, fallback server, authentication,
/// connection status, sync status, Sync Now, and the destructive
/// Disconnect & Erase Local Data action.
struct ConnectionSyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = SettingsViewModel()
    @State private var isSyncingNow = false
    @State private var isEraseLocalDataConfirmationPresented = false
    @State private var isErasingLocalData = false

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Server") {
                    TextField(
                        "Required",
                        text: $viewModel.serverURLString,
                        prompt: Text("https://actual.example.com")
                    )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("Fallback Server") {
                    TextField(
                        "Optional",
                        text: $viewModel.fallbackServerURLString,
                        prompt: Text("https://actual.tailnet.ts.net")
                    )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            viewModel.commitFallbackServerURL(using: appState)
                        }
                }

                Text("The fallback server is tried automatically when the primary server can't be reached — for example, a Tailscale URL when you're away from home Wi-Fi.")
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)

                LabeledContent("Password") {
                    SecureField(passwordPrompt, text: $viewModel.actualPassword)
                        .textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing)
                }

                if appState.hasSyncCredentials {
                    Text("Your password is not stored. Actualist keeps a sync token and only needs the password again to reconnect.")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }

                if let warning = viewModel.connectionSecurityWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.warning)
                }
            }
            .settingsSectionChrome()

            Section("Status") {
                SettingsStatusRow(status: appState.connectionStatus)

                LabeledContent("Last Synced") {
                    Text(lastSyncedText)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }

                LabeledContent("Pending Sync") {
                    Text(pendingSyncText)
                        .foregroundStyle(pendingSyncForeground)
                }

                if let message = appState.lastErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                }

                if let error = appState.localFirstSyncStatus?.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                }
            }
            .settingsSectionChrome()

            Section {
                Button {
                    appState.beginReauthentication()
                } label: {
                    SettingsActionLabel(
                        title: "Sign In Again",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                .disabled(viewModel.isTesting)

                Button {
                    Task { await viewModel.saveAndTest(using: appState) }
                } label: {
                    SettingsActionLabel(
                        title: viewModel.isTesting ? "Checking" : "Save Connection",
                        systemImage: "network"
                    )
                }
                .disabled(!canSaveConnection)

                Button {
                    Task { await syncNow() }
                } label: {
                    SettingsActionLabel(
                        title: isSyncingNow ? "Syncing" : "Sync Now",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(isSyncingNow || appState.settings.selectedBudgetID == nil)
            }
            .settingsSectionChrome()

            Section {
                Button(role: .destructive) {
                    isEraseLocalDataConfirmationPresented = true
                } label: {
                    SettingsActionLabel(
                        title: isErasingLocalData ? "Erasing" : "Disconnect & Erase Local Data",
                        systemImage: "trash"
                    )
                }
                .disabled(isErasingLocalData)
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Removes the sync token, cached encryption keys, imported budget files, and local selections from this device. Your server data is not changed.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Connection & Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.hydrate(from: appState)
        }
        .onDisappear {
            viewModel.commitFallbackServerURL(using: appState)
        }
        .refreshable {
            await syncNow()
        }
        .confirmationDialog(
            "Disconnect & Erase Local Data?",
            isPresented: $isEraseLocalDataConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Disconnect & Erase", role: .destructive) {
                eraseLocalData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(eraseLocalDataConfirmationMessage)
        }
    }

    private var passwordPrompt: String {
        appState.hasSyncCredentials ? "Re-enter to reconnect" : "Required"
    }

    private var canSaveConnection: Bool {
        guard !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !viewModel.isTesting else {
            return false
        }

        return !viewModel.actualPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var lastSyncedText: String {
        guard let lastSyncedAt = appState.localFirstSyncStatus?.lastSyncedAt else {
            return "Unknown"
        }
        return lastSyncedAt.formatted(.relative(presentation: .named))
    }

    private var pendingSyncText: String {
        let count = appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        if count == 0 {
            return "None"
        }
        return count == 1 ? "1 change" : "\(count) changes"
    }

    private var pendingSyncForeground: Color {
        let count = appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        return count == 0 ? ActualistTheme.secondaryText : ActualistTheme.warning
    }

    private var eraseLocalDataConfirmationMessage: String {
        let base = "Actualist will remove the sync token, cached encryption keys, imported budget files, and local selections from this device."
        let pendingCount = appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        guard pendingCount > 0 else {
            return "\(base) Your server data is not changed."
        }
        let noun = pendingCount == 1 ? "change" : "changes"
        return "\(base) Warning: \(pendingCount) local \(noun) have not been confirmed by the server and will be permanently lost."
    }

    private func syncNow() async {
        guard let budgetID = appState.settings.selectedBudgetID, !isSyncingNow else {
            return
        }
        isSyncingNow = true
        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        isSyncingNow = false
    }

    private func eraseLocalData() {
        guard !isErasingLocalData else {
            return
        }
        isErasingLocalData = true
        appState.disconnectAndEraseLocalData()
        viewModel.actualPassword = ""
        viewModel.serverURLString = appState.settings.localFirstServerURLString
        viewModel.fallbackServerURLString = appState.settings.fallbackServerURLString
        isErasingLocalData = false
    }
}
