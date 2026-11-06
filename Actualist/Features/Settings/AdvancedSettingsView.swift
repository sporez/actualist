import SwiftUI

#if DEBUG
/// Advanced settings: developer tools, compiled into Debug and Dev builds only.
struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var isDeveloperDiagnosticsPresented = false

    var body: some View {
        List {
            Section("Developer") {
                Button {
                    isDeveloperDiagnosticsPresented = true
                } label: {
                    SettingsActionLabel(title: "Developer", systemImage: "wrench.and.screwdriver")
                }
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isDeveloperDiagnosticsPresented) {
            SettingsDeveloperDiagnosticsSheet(
                debug: appState.settings.backgroundRefreshDebug,
                syncStatus: appState.localFirstSyncStatus,
                syncDebug: appState.settings.localFirstSyncDebug,
                endpointHealth: appState.localFirstStore.endpointHealthDisplay,
                retryPendingSync: appState.retryPendingLocalFirstSync
            )
            .environment(appState)
        }
    }
}
#endif
