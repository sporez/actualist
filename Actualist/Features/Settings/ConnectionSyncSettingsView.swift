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
            if appState.isDemoMode {
                Section {
                    LabeledContent {
                        Text("Local demo — no server, no sync")
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } label: {
                        Label("Demo Mode", systemImage: "testtube.2")
                            .foregroundStyle(ActualistTheme.primaryText)
                    }
                    Text("You're exploring Actualist with bundled sample data."
                        + " Changes stay on this device and never sync."
                        + " Exit demo mode to connect to your own Actual server.")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()

                Section {
                    Button(role: .destructive) {
                        isEraseLocalDataConfirmationPresented = true
                    } label: {
                        SettingsActionLabel(
                            title: isErasingLocalData ? "Exiting" : "Exit Demo Mode",
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                    .disabled(isErasingLocalData)
                } header: {
                    Text("Demo")
                } footer: {
                    Text("Removes the demo budget and returns to onboarding so you can connect to an Actual server.")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()
            } else {
                serverSection
                statusSection
                actionsSection
                eraseSection
            }
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
            appState.isDemoMode ? "Exit Demo Mode?" : "Disconnect & Erase Local Data?",
            isPresented: $isEraseLocalDataConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(appState.isDemoMode ? "Exit Demo Mode" : "Disconnect & Erase", role: .destructive) {
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
        if appState.isDemoMode {
            return "Actualist will remove the demo budget and return to onboarding."
        }
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

    // MARK: - Non-demo sections (extracted so the demo body can omit them)

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            LabeledURLField(
                title: "Server",
                placeholder: "https://actual.example.com",
                text: $viewModel.serverURLString
            )

            LabeledURLField(
                title: "Fallback Server",
                placeholder: "https://actual.tailnet.ts.net",
                text: $viewModel.fallbackServerURLString,
                onSubmit: { viewModel.commitFallbackServerURL(using: appState) }
            )

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
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            SettingsStatusRow(
                status: appState.connectionStatus,
                usedFallback: appState.localFirstSyncStatus?.lastSyncUsedFallback ?? false
            )

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

            if let error = appState.localFirstSyncStatus?.lastError,
               error != appState.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
            }
        }
        .settingsSectionChrome()
    }

    @ViewBuilder
    private var actionsSection: some View {
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
    }

    @ViewBuilder
    private var eraseSection: some View {
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
}

/// Full-width, label-above text field for entering a server URL. Matches the
/// iOS 26 form pattern used by Wi-Fi ▸ Configure Proxy: a small caption label
/// above a plain leading-aligned field, so the start of a long URL stays
/// visible while typing instead of scrolling away under trailing alignment.
private struct LabeledURLField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(ActualistTheme.secondaryText)

            TextField(title, text: $text, prompt: Text(placeholder))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .submitLabel(.done)
                .onSubmit { onSubmit?() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
