import SwiftUI

/// Advanced settings: experimental features and developer tools.
struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var isDeveloperDiagnosticsPresented = false
    @State private var hideDeveloperModeTask: Task<Void, Never>?
    #if DEBUG
    @State private var isPostingDebugNotification = false
    @State private var debugNotificationMessage: String?
    #endif

    var body: some View {
        List {
            Section {
                Label {
                    Text("Experimental features are unfinished and may break or corrupt your budget. Enable them only if you accept that risk.")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ActualistTheme.warning)
                }

                ForEach(ExperimentalFeature.allCases) { feature in
                    Toggle(isOn: experimentalFeatureSelection(feature)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(feature.title)
                                .foregroundStyle(ActualistTheme.primaryText)
                            Text(feature.detail)
                                .font(.caption)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }
                }
            } header: {
                Text("Experimental Features")
            } footer: {
                Text("Budget Templates is experimental while in development.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            if appState.settings.developerModeUnlocked {
                Section("Developer") {
                    Button {
                        isDeveloperDiagnosticsPresented = true
                    } label: {
                        SettingsActionLabel(title: "Developer", systemImage: "wrench.and.screwdriver")
                    }
                }
                .settingsSectionChrome()
            }
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isDeveloperDiagnosticsPresented) {
            #if DEBUG
            SettingsDeveloperDiagnosticsSheet(
                randomizedDisplayValuesSelection: randomizedDisplayValuesSelection,
                hideDeveloperMode: hideDeveloperMode,
                debug: appState.settings.backgroundRefreshDebug,
                syncStatus: appState.localFirstSyncStatus,
                syncDebug: appState.settings.localFirstSyncDebug,
                endpointHealth: appState.localFirstStore.endpointHealthDisplay,
                retryPendingSync: appState.retryPendingLocalFirstSync,
                isPostingDebugNotification: $isPostingDebugNotification,
                debugNotificationMessage: $debugNotificationMessage,
                postDebugNotification: postDebugNotification
            )
            #else
            SettingsDeveloperDiagnosticsSheet(
                randomizedDisplayValuesSelection: randomizedDisplayValuesSelection,
                hideDeveloperMode: hideDeveloperMode,
                debug: appState.settings.backgroundRefreshDebug,
                syncStatus: appState.localFirstSyncStatus,
                syncDebug: appState.settings.localFirstSyncDebug,
                endpointHealth: appState.localFirstStore.endpointHealthDisplay,
                retryPendingSync: appState.retryPendingLocalFirstSync
            )
            #endif
        }
    }

    private var randomizedDisplayValuesSelection: Binding<Bool> {
        Binding {
            appState.settings.randomizedDisplayValuesEnabled
        } set: { isEnabled in
            appState.updateRandomizedDisplayValuesEnabled(isEnabled)
        }
    }

    private func experimentalFeatureSelection(_ feature: ExperimentalFeature) -> Binding<Bool> {
        Binding {
            appState.isExperimentalFeatureEnabled(feature)
        } set: { isEnabled in
            appState.updateExperimentalFeature(feature, isEnabled: isEnabled)
        }
    }

    private func hideDeveloperMode() {
        appState.updateDeveloperModeUnlocked(false)
        isDeveloperDiagnosticsPresented = false
        hideDeveloperModeTask = DeveloperUnlockToast.present(
            "Developer Mode hidden",
            on: appState,
            replacing: hideDeveloperModeTask
        )
    }

    #if DEBUG
    private func postDebugNotification() async {
        isPostingDebugNotification = true
        debugNotificationMessage = nil
        defer { isPostingDebugNotification = false }

        do {
            try await appState.postDebugNewTransactionNotification()
            debugNotificationMessage = "Test alert will post in 5 seconds. Send Actualist to the background, then tap the notification."
        } catch {
            debugNotificationMessage = error.localizedDescription
        }
    }
    #endif
}
