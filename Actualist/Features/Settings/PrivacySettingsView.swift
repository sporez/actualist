import SwiftUI

/// Privacy & Notifications: transaction alerts, sample-value masking, app
/// switcher protection, and Shortcuts / Siri access.
///
/// "Include Rollover in Alerts" lives in Appearance — it controls the overspent
/// banner on the Budget screen, not notification delivery.
struct PrivacySettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            Section {
                Toggle("New Transaction Alerts", isOn: backgroundRefreshSelection)
                    .disabled(appState.isDemoMode)
            } header: {
                Text("Notifications")
            } footer: {
                Text(transactionAlertsFooterText)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            Section {
                Picker("App Switcher", selection: appSwitcherPrivacyModeSelection) {
                    ForEach(AppSwitcherPrivacyMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Use Sample Values", isOn: sampleValuesSelection)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Controls how Actualist protects your financial information when displaying the app or sharing screenshots.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            Section {
                Toggle("Allow Shortcuts & Siri", isOn: shortcutsEnabledSelection)
            } header: {
                Text("System Access")
            } footer: {
                Text("Shortcuts and Siri can read balances and log transactions in the selected budget.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Privacy & Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var backgroundRefreshSelection: Binding<Bool> {
        Binding {
            appState.settings.backgroundTransactionRefreshEnabled
        } set: { isEnabled in
            Task {
                await appState.updateBackgroundTransactionRefreshEnabled(isEnabled)
            }
        }
    }

    private var appSwitcherPrivacyModeSelection: Binding<AppSwitcherPrivacyMode> {
        Binding {
            appState.settings.appSwitcherPrivacyMode
        } set: { mode in
            appState.updateAppSwitcherPrivacyMode(mode)
        }
    }

    private var sampleValuesSelection: Binding<Bool> {
        Binding {
            appState.settings.randomizedDisplayValuesEnabled
        } set: { isEnabled in
            appState.updateRandomizedDisplayValuesEnabled(isEnabled)
        }
    }

    private var shortcutsEnabledSelection: Binding<Bool> {
        Binding {
            appState.settings.shortcutsEnabled
        } set: { isEnabled in
            appState.updateShortcutsEnabled(isEnabled)
        }
    }

    private var transactionAlertsFooterText: String {
        if appState.isDemoMode {
            return "Background transaction alerts aren't available in demo mode, which never contacts a server."
        }
        return "Actualist checks for new transactions using background refresh. Notifications must be enabled in Settings."
    }
}
