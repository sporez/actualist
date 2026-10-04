import SwiftUI

/// Advanced settings: developer tools unlocked from the Settings title.
struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var isDeveloperDiagnosticsPresented = false
    @State private var hideDeveloperModeTask: Task<Void, Never>?

    var body: some View {
        List {
            if appState.settings.developerModeUnlocked {
                Section("Developer") {
                    Button {
                        isDeveloperDiagnosticsPresented = true
                    } label: {
                        SettingsActionLabel(title: "Developer", systemImage: "wrench.and.screwdriver")
                    }
                }
                .settingsSectionChrome()
            } else {
                Text("Developer tools are locked.")
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isDeveloperDiagnosticsPresented) {
            SettingsDeveloperDiagnosticsSheet(
                hideDeveloperMode: hideDeveloperMode,
                debug: appState.settings.backgroundRefreshDebug,
                syncStatus: appState.localFirstSyncStatus,
                syncDebug: appState.settings.localFirstSyncDebug,
                endpointHealth: appState.localFirstStore.endpointHealthDisplay,
                retryPendingSync: appState.retryPendingLocalFirstSync
            )
            .environment(appState)
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

}
