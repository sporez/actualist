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

    var body: some View {
        List {
            if appState.isDemoMode {
                Section {
                    LabeledContent {
                        Text("Demo only. No server.")
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } label: {
                        Label("Demo Mode", systemImage: "testtube.2")
                            .foregroundStyle(ActualistTheme.primaryText)
                    }
                    Text("You are using sample data."
                        + " Changes stay on this device."
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
                            title: "Exit Demo Mode",
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                    .eraseLocalDataConfirmationDialog(
                        isPresented: $isEraseLocalDataConfirmationPresented,
                        isDemoMode: true,
                        message: eraseLocalDataConfirmationMessage,
                        onConfirm: eraseLocalData
                    )
                } header: {
                    Text("Demo")
                } footer: {
                    Text("Removes the demo budget so you can connect to your own Actual server.")
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
            viewModel.hydrateConnectionIfNeeded(from: appState)
        }
        .onDisappear {
            viewModel.commitFallbackServerURL(using: appState)
        }
        .refreshable {
            await syncNow()
        }
    }

    private var passwordPrompt: String {
        switch appState.credentialAvailability {
        case .available: "Enter to reconnect"
        case .absent: "Required"
        case .unavailable: "Cannot read saved sign-in"
        }
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
            return "Nothing"
        }
        return count == 1 ? "1 change" : "\(count) changes"
    }

    private var pendingSyncForeground: Color {
        let count = appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        return count == 0 ? ActualistTheme.secondaryText : ActualistTheme.warning
    }

    private var eraseLocalDataConfirmationMessage: String {
        if appState.isDemoMode {
            return "Actualist will remove the demo budget so you can connect to your own Actual server."
        }
        let base = "Actualist will sign you out and remove this budget and your settings from this device."
        return LocalDataLossWarning.message(
            base: base,
            pendingChangeCount: appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        )
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
        Task {
            await appState.disconnectAndEraseLocalData()
            viewModel.actualPassword = ""
            viewModel.serverURLString = appState.settings.localFirstServerURLString
            viewModel.fallbackServerURLString = appState.settings.fallbackServerURLString
        }
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

            if let error = viewModel.fallbackServerURLError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
            }

            Text("Actualist uses the fallback server when it cannot reach the main server, such as a Tailscale address when you are away from home.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)

            NavigationLink {
                CustomHeadersSettingsView(
                    store: appState.localFirstStore,
                    primaryURLString: viewModel.serverURLString,
                    fallbackURLString: viewModel.fallbackServerURLString
                )
            } label: {
                LabeledContent("Custom Headers", value: viewModel.customHeadersSummary(using: appState.localFirstStore))
            }

            LabeledContent("Password") {
                SecureField(passwordPrompt, text: $viewModel.actualPassword)
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
            }

            if appState.hasSyncCredentials {
                Text("Actualist does not save your password. You only need it again if you have to reconnect.")
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
            if let recoveryMessage = appState.credentialRecoveryMessage {
                Text(recoveryMessage)
                    .foregroundStyle(ActualistTheme.warning)
                Button("Try Again") {
                    Task { await appState.retryCredentialAccess() }
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("credentialRecoveryRetry")
            }
            SettingsStatusRow(
                status: appState.connectionStatus,
                usedFallback: appState.localFirstSyncStatus?.lastSyncUsedFallback ?? false
            )

            LabeledContent("Last Synced") {
                Text(lastSyncedText)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            LabeledContent("Waiting to Upload") {
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
                Text(SafeSyncDiagnostic.storedError(error))
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
            .disabled(!viewModel.canSaveConnection)

            Button {
                Task { await syncNow() }
            } label: {
                SettingsActionLabel(
                    title: isSyncingNow ? "Syncing" : "Sync Now",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(isSyncingNow || appState.settings.selectedBudgetID == nil)
        } header: {
            Text("Connection")
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
                    title: "Disconnect and Erase Data",
                    systemImage: "trash"
                )
            }
            .eraseLocalDataConfirmationDialog(
                isPresented: $isEraseLocalDataConfirmationPresented,
                isDemoMode: false,
                message: eraseLocalDataConfirmationMessage,
                onConfirm: eraseLocalData
            )
        } header: {
            Text("Danger Zone")
        } footer: {
            Text("Signs you out and removes this budget and your settings from this device. Your data on the server is not changed.")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }
}

private extension View {
    func eraseLocalDataConfirmationDialog(
        isPresented: Binding<Bool>,
        isDemoMode: Bool,
        message: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            isDemoMode ? "Exit Demo Mode?" : "Disconnect and Erase Data?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(
                isDemoMode ? "Exit Demo Mode" : "Disconnect & Erase",
                role: .destructive,
                action: onConfirm
            )
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
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
