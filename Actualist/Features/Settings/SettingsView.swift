import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let showsDismissButton: Bool
    @State private var developerUnlockToastTask: Task<Void, Never>?

    init(showsDismissButton: Bool = false) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ConnectionSyncSettingsView()
                    } label: {
                        SettingsCategoryRow(
                            systemImage: "antenna.radiowaves.left.and.right",
                            title: "Connection & Sync",
                            subtitle: connectionSubtitle,
                            subtitleColor: connectionSubtitleColor
                        )
                    }

                    NavigationLink {
                        BudgetDataSettingsView()
                    } label: {
                        SettingsCategoryRow(
                            systemImage: "banknote",
                            title: "Budget & Data",
                            subtitle: budgetSubtitle
                        )
                    }
                }
                .settingsSectionChrome()

                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        SettingsCategoryRow(
                            systemImage: "bell.badge",
                            title: "Notifications",
                            subtitle: notificationsSubtitle
                        )
                    }

                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsCategoryRow(
                            systemImage: "paintbrush",
                            title: "Appearance",
                            subtitle: appearanceSubtitle
                        )
                    }

                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        SettingsCategoryRow(
                            systemImage: "hand.raised.fill",
                            title: "Privacy",
                            subtitle: privacySubtitle
                        )
                    }

                    NavigationLink {
                        ReportsSettingsView()
                    } label: {
                        SettingsCategoryRow(
                            systemImage: "chart.xyaxis.line",
                            title: "Reports",
                            subtitle: reportsSubtitle
                        )
                    }
                }
                .settingsSectionChrome()

                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        SettingsCategoryRow(
                            systemImage: "wrench.and.screwdriver",
                            title: "Advanced",
                            subtitle: advancedSubtitle
                        )
                    }

                    NavigationLink {
                        SupportSettingsView()
                    } label: {
                        SettingsCategoryRow(
                            systemImage: "questionmark.circle",
                            title: "Support",
                            subtitle: supportSubtitle
                        )
                    }
                } footer: {
                    Text(appVersionText)
                        .font(.caption2)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button {
                        recordDeveloperUnlockTap()
                    } label: {
                        Text("Settings")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isHeader)
                }

                if showsDismissButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close Settings")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            developerUnlockToast
        }
    }

    @ViewBuilder
    private var developerUnlockToast: some View {
        if let developerUnlockToastMessage = appState.developerUnlockToastMessage {
            Text(developerUnlockToastMessage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(ActualistTheme.elevatedSurface, in: Capsule())
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Live status subtitles

    private var connectionSubtitle: String {
        let statusWord: String
        switch appState.connectionStatus {
        case .online: statusWord = "Connected"
        case .connecting: statusWord = "Checking"
        case .offline: statusWord = "Offline"
        }

        if let lastSyncedAt = appState.localFirstSyncStatus?.lastSyncedAt {
            return "\(statusWord) · Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))"
        }
        return statusWord
    }

    private var connectionSubtitleColor: Color {
        switch appState.connectionStatus {
        case .online: ActualistTheme.positive
        case .connecting: ActualistTheme.warning
        case .offline: ActualistTheme.danger
        }
    }

    private var budgetSubtitle: String {
        guard appState.settings.selectedBudgetID != nil else {
            return "None"
        }
        let security = appState.localFirstSyncStatus?.encryptionKeyID != nil
            ? "Encrypted"
            : "Not encrypted"
        return "\(selectedBudgetDisplayName) · \(security)"
    }

    private var notificationsSubtitle: String {
        appState.settings.backgroundTransactionRefreshEnabled
            ? "Alerts on"
            : "Alerts off"
    }

    private var appearanceSubtitle: String {
        let themeName = appState.settings.theme.title
            .replacingOccurrences(of: " (dark)", with: "")
            .replacingOccurrences(of: " (light)", with: "")
        return "\(themeName) · \(appState.settings.displayDensity.title)"
    }

    private var privacySubtitle: String {
        switch appState.settings.appSwitcherPrivacyMode {
        case .off: "App Switcher off"
        case .whenBackgrounded: "App Switcher · When Backgrounded"
        case .always: "App Switcher · Always"
        }
    }

    private var reportsSubtitle: String {
        appState.settings.reportCardOrder == ReportCardOrderPreference.defaultOrder
            ? "Default order"
            : "Custom order"
    }

    private var advancedSubtitle: String {
        appState.settings.developerModeUnlocked
            ? "Developer · Experimental"
            : "Experimental Features"
    }

    private var supportSubtitle: String {
        "Diagnostics · Bug Report"
    }

    private var selectedBudgetDisplayName: String {
        PrivacyDisplay.selectedBudgetName(
            name: appState.settings.selectedBudgetName,
            id: appState.settings.selectedBudgetID,
            randomized: appState.settings.randomizedDisplayValuesEnabled
        )
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        guard let version, !version.isEmpty,
              let build, !build.isEmpty else {
            return "Actualist"
        }

        return "Actualist \(version) (\(build))"
    }

    // MARK: - Developer unlock

    private func recordDeveloperUnlockTap() {
        if let message = appState.recordDeveloperUnlockTap() {
            developerUnlockToastTask = DeveloperUnlockToast.present(
                message,
                on: appState,
                replacing: developerUnlockToastTask
            )
        }
    }
}
