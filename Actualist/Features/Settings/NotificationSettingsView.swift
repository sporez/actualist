import SwiftUI

/// Notification settings: new transaction alerts.
///
/// "Include Rollover in Alerts" lives in Appearance — it controls the overspent
/// banner on the Budget screen, not notification delivery.
struct NotificationSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            Section {
                Toggle("New Transaction Alerts", isOn: backgroundRefreshSelection)
                    .disabled(appState.isDemoMode)
            } header: {
                Text("Transaction Alerts")
            } footer: {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Notifications")
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

    private var footerText: String {
        if appState.isDemoMode {
            return "Background transaction alerts aren't available in demo mode, which never contacts a server."
        }
        return "Actualist checks for new transactions using background refresh. Alerts require notifications to be allowed for Actualist in Settings › Notifications."
    }
}
