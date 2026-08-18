import SwiftUI

/// Privacy settings: app switcher protection and future privacy/security options.
struct PrivacySettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            Section {
                Picker("App Switcher", selection: appSwitcherPrivacyModeSelection) {
                    ForEach(AppSwitcherPrivacyMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("App Switcher")
            } footer: {
                Text(appState.settings.appSwitcherPrivacyMode.detail)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appSwitcherPrivacyModeSelection: Binding<AppSwitcherPrivacyMode> {
        Binding {
            appState.settings.appSwitcherPrivacyMode
        } set: { mode in
            appState.updateAppSwitcherPrivacyMode(mode)
        }
    }
}
