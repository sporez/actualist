import SwiftUI

/// Slugs for Settings pages. Launch paths use these values (`appearance`,
/// `settings/privacy`). Unique slugs also work as `-actualist-screen` shorthand.
enum SettingsPage: String, CaseIterable, Hashable, Sendable {
    case connection
    case budgetData = "budget-data"
    case templates
    case bankSync = "bank-sync"
    case appearance
    case privacy
    case reports
    case advanced
    case support

    static func stack(fromScreenPath path: [String]) -> [SettingsPage] {
        if path.first == "settings" {
            return path.dropFirst().compactMap(SettingsPage.init(rawValue:))
        }
        if let first = path.first, AppTab(rawValue: first) != nil {
            return []
        }
        return path.compactMap(SettingsPage.init(rawValue:))
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let showsDismissButton: Bool
    @State private var path: [SettingsPage] = []
    @State private var didApplyLaunchDestination = false
    @State private var developerUnlockToastTask: Task<Void, Never>?

    init(showsDismissButton: Bool = false) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: SettingsPage.connection) {
                        SettingsCategoryRow(
                            systemImage: "antenna.radiowaves.left.and.right",
                            title: "Connection & Sync",
                            subtitle: connectionSubtitle,
                            subtitleColor: connectionSubtitleColor
                        )
                    }

                    NavigationLink(value: SettingsPage.budgetData) {
                        SettingsCategoryRow(
                            systemImage: "banknote",
                            title: "Budget & Data",
                            subtitle: budgetSubtitle
                        )
                    }
                }
                .settingsSectionChrome()

                Section {
                    NavigationLink(value: SettingsPage.templates) {
                        SettingsCategoryRow(
                            systemImage: "sparkles",
                            title: "Templates",
                            subtitle: templatesSubtitle
                        )
                    }
                }
                .settingsSectionChrome()

                Section {
                    NavigationLink(value: SettingsPage.appearance) {
                        SettingsCategoryRow(
                            systemImage: "paintbrush",
                            title: "Appearance",
                            subtitle: appearanceSubtitle
                        )
                    }

                    NavigationLink(value: SettingsPage.privacy) {
                        SettingsCategoryRow(
                            systemImage: "hand.raised.fill",
                            title: "Privacy & Notifications",
                            subtitle: privacySubtitle
                        )
                    }

                    NavigationLink(value: SettingsPage.reports) {
                        SettingsCategoryRow(
                            systemImage: "chart.xyaxis.line",
                            title: "Reports",
                            subtitle: reportsSubtitle
                        )
                    }
                }
                .settingsSectionChrome()

                Section {
                    NavigationLink(value: SettingsPage.advanced) {
                        SettingsCategoryRow(
                            systemImage: "wrench.and.screwdriver",
                            title: "Advanced",
                            subtitle: advancedSubtitle
                        )
                    }

                    NavigationLink(value: SettingsPage.support) {
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
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .connection:
                    ConnectionSyncSettingsView()
                case .budgetData:
                    BudgetDataSettingsView()
                case .templates:
                    BudgetTemplatesBrowserView()
                case .bankSync:
                    BankSyncView()
                case .appearance:
                    AppearanceSettingsView()
                case .privacy:
                    PrivacySettingsView()
                case .reports:
                    ReportsSettingsView()
                case .advanced:
                    AdvancedSettingsView()
                case .support:
                    SupportSettingsView()
                }
            }
            .onAppear {
                applyLaunchDestination()
            }
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
        if appState.isDemoMode {
            return "Demo mode"
        }
        let statusWord: String
        switch appState.connectionStatus {
        case .online: statusWord = "Connected"
        case .connecting: statusWord = "Checking"
        case .offline: statusWord = "Offline"
        }

        if let lastSyncedAt = appState.localFirstSyncStatus?.lastSyncedAt {
            return "\(statusWord) · \(compactSyncedAgo(from: lastSyncedAt))"
        }
        return statusWord
    }

    /// Compact relative time for the connection subtitle, e.g. "5m ago".
    private func compactSyncedAgo(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 45 {
            return "just now"
        }
        let minutes = Int(seconds / 60)
        if minutes < 1 {
            return "<1m ago"
        }
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }

    private var connectionSubtitleColor: Color {
        if appState.isDemoMode {
            return ActualistTheme.secondaryText
        }
        switch appState.connectionStatus {
        case .online: return ActualistTheme.positive
        case .connecting: return ActualistTheme.warning
        case .offline: return ActualistTheme.danger
        }
    }

    private var templatesSubtitle: String {
        appState.settings.selectedBudgetID == nil ? "None" : "Category templates"
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

    private var appearanceSubtitle: String {
        let themeName = appState.settings.theme.title
            .replacingOccurrences(of: " (dark)", with: "")
            .replacingOccurrences(of: " (light)", with: "")
        return "\(themeName) · \(appState.settings.displayDensity.title)"
    }

    private var privacySubtitle: String {
        appState.settings.backgroundTransactionRefreshEnabled
            ? "Alerts on"
            : "Alerts off"
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

    // MARK: - Simulator launch

    private func applyLaunchDestination() {
        guard !didApplyLaunchDestination else {
            return
        }
        didApplyLaunchDestination = true

        path = SettingsPage.stack(
            fromScreenPath: SimulatorLaunchCommand.fromProcessInfo()?.screenPath ?? []
        )
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
