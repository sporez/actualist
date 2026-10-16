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
                Text("Hide your amounts in the app switcher. Sample Values shows made-up names and amounts instead of your real ones.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            Section {
                Toggle("Allow Shortcuts & Siri", isOn: shortcutsEnabledSelection)
                Toggle("Allow Logging While Locked", isOn: shortcutsLockedLoggingSelection)
                    .disabled(!appState.settings.shortcutsEnabled || appState.isDemoMode)
            } header: {
                Text("System Access")
            } footer: {
                Text("Shortcuts and Siri can read balances and log transactions in your budget. With Allow Logging While Locked, logging also works while your device is locked. Everything else needs you to unlock.")
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

    private var shortcutsLockedLoggingSelection: Binding<Bool> {
        Binding {
            appState.settings.shortcutsLockedLoggingEnabled
        } set: { isEnabled in
            appState.updateShortcutsLockedLoggingEnabled(isEnabled)
        }
    }

    private var transactionAlertsFooterText: String {
        if appState.isDemoMode {
            return "Transaction alerts are not available in demo mode."
        }
        return "Actualist checks for new transactions in the background. To see alerts, allow notifications for Actualist in the iOS Settings app."
    }
}
