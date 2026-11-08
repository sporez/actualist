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

            if AppInstallationIdentity.current == .development {
                Section {
                    Toggle("Share App Store Links", isOn: Binding(
                        get: { appState.settings.devSharesAppStoreLinks },
                        set: { appState.updateDevSharesAppStoreLinks($0) }
                    ))
                } header: {
                    Text("Sharing")
                } footer: {
                    Text("Shared transaction links open in the App Store version of Actualist instead of this Dev build.")
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
