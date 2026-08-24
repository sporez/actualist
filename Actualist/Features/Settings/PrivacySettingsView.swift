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
                Text("Transaction Alerts")
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
            } header: {
                Text("App Switcher")
            } footer: {
                Text(appState.settings.appSwitcherPrivacyMode.detail)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            Section {
                Toggle("Use Sample Values", isOn: sampleValuesSelection)
            } header: {
                Text("Sample Values")
            } footer: {
                Text("Replaces amounts, account names, payees, and categories with sample values. Your real budget is unchanged and still syncs normally.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            Section {
                Toggle("Allow Shortcuts & Siri", isOn: shortcutsEnabledSelection)
            } footer: {
                Text("Shortcuts and Siri can read balances and log transactions in the selected budget. Turn this off to refuse every action. The device passcode or Face ID is still required for money actions.")
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
        return "Actualist checks for new transactions using background refresh. Alerts require notifications to be allowed for Actualist in Settings › Notifications."
    }
}
