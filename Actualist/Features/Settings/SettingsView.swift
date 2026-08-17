import SwiftUI

private enum SettingsDeveloperUnlock {
    static let toastDurationSeconds: Double = 1.4
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let showsDismissButton: Bool
    @State private var viewModel = SettingsViewModel()
    @State private var isBudgetPickerPresented = false
    @State private var isAppIconPickerPresented = false
    @State private var isAccountOrderPresented = false
    @State private var isReportOrderExpanded = false
    @State private var isDeveloperDiagnosticsPresented = false
    @State private var developerUnlockToastTask: Task<Void, Never>?
    @State private var isSyncingNow = false
    @State private var isReimporting = false
    @State private var isReimportConfirmationPresented = false
    @State private var isEraseLocalDataConfirmationPresented = false
    @State private var isErasingLocalData = false
    @State private var diagnosticReportCopied = false
    #if DEBUG
    @State private var isPostingDebugNotification = false
    @State private var debugNotificationMessage: String?
    #endif

    init(showsDismissButton: Bool = false) {
        self.showsDismissButton = showsDismissButton
    }

    private static let newIssueURL = URL(string: "https://github.com/sporez/actualist/issues/new")!
    private static let privacyPolicyURL = URL(string: "https://github.com/sporez/actualist/blob/main/PRIVACY.md")!

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Server") {
                        TextField(
                            "Required",
                            text: $viewModel.serverURLString,
                            prompt: Text("https://actual.example.com")
                        )
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Fallback Server") {
                        TextField(
                            "Optional",
                            text: $viewModel.fallbackServerURLString,
                            prompt: Text("https://actual.tailnet.ts.net")
                        )
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                viewModel.commitFallbackServerURL(using: appState)
                            }
                    }

                    Text("The fallback server is tried automatically when the primary server can't be reached — for example, a Tailscale URL when you're away from home Wi-Fi.")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)

                    LabeledContent("Password") {
                        SecureField(passwordPrompt, text: $viewModel.actualPassword)
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }

                    if appState.hasSyncCredentials {
                        Text("Your password is not stored. Actualist keeps a sync token and only needs the password again to reconnect.")
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    if let warning = viewModel.connectionSecurityWarning {
                        Text(warning)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.warning)
                    }

                    SettingsStatusRow(status: appState.connectionStatus)

                    Button {
                        appState.beginReauthentication()
                    } label: {
                        SettingsActionLabel(
                            title: "Sign In Again",
                            systemImage: "person.crop.circle.badge.checkmark"
                        )
                    }
                    .disabled(viewModel.isTesting)

                    if let message = appState.lastErrorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.danger)
                    }

                    Button {
                        Task { await viewModel.saveAndTest(using: appState) }
                    } label: {
                        SettingsActionLabel(
                            title: viewModel.isTesting ? "Checking" : "Save Connection",
                            systemImage: "network"
                        )
                    }
                    .disabled(!canSaveConnection)

                    Button(role: .destructive) {
                        isEraseLocalDataConfirmationPresented = true
                    } label: {
                        SettingsActionLabel(
                            title: isErasingLocalData ? "Erasing" : "Disconnect & Erase Local Data",
                            systemImage: "trash"
                        )
                    }
                    .disabled(isErasingLocalData)
                }
                .settingsSectionChrome()

                Section("Budget") {
                    LabeledContent("Selected") {
                        Text(selectedBudgetDisplayName)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    LabeledContent("Last Synced") {
                        Text(localFirstLastSyncedText)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    LabeledContent("Pending Sync") {
                        Text(localFirstPendingSyncText)
                            .foregroundStyle(localFirstPendingSyncForeground)
                    }

                    LabeledContent("Security") {
                        Text(localFirstSecurityText)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    if let error = appState.localFirstSyncStatus?.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.danger)
                    }

                    NavigationLink {
                        PayeesView()
                    } label: {
                        SettingsActionLabel(title: "Payees", systemImage: "person.2")
                    }
                    .disabled(appState.settings.selectedBudgetID == nil)

                    Button {
                        isBudgetPickerPresented = true
                    } label: {
                        SettingsActionLabel(title: "Change Budget", systemImage: "folder")
                    }

                    Button {
                        Task { await syncNow() }
                    } label: {
                        SettingsActionLabel(
                            title: isSyncingNow ? "Syncing" : "Sync Now",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(isSyncingNow || appState.settings.selectedBudgetID == nil)

                    Button(role: .destructive) {
                        isReimportConfirmationPresented = true
                    } label: {
                        SettingsActionLabel(
                            title: isReimporting ? "Reimporting" : "Reimport Budget",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(isReimporting || appState.settings.selectedBudgetID == nil)
                }
                .settingsSectionChrome()

                Section("Privacy") {
                    Picker("App Switcher", selection: appSwitcherPrivacyModeSelection) {
                        ForEach(AppSwitcherPrivacyMode.allCases) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(appState.settings.appSwitcherPrivacyMode.detail)
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()

                Section("Background Refresh") {
                    Toggle("New Transaction Alerts", isOn: backgroundRefreshSelection)
                }
                .settingsSectionChrome()

                Section("Appearance") {
                    Picker("Theme", selection: themeSelection) {
                        ForEach(ActualistThemeOption.allCases) { option in
                            Text(option.title)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    ThemePreviewStrip(theme: appState.settings.theme)

                    Toggle(isOn: greenIncomeTransactionAmountsSelection) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Green Income Amounts")
                            Text("Show positive transaction amounts in green.")
                                .font(.caption)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }

                    Toggle(isOn: includeCarryoverCategoriesInOverspentAlertsSelection) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Include Rollover in Alerts")
                            Text("Show negative rollover categories in the overspent banner and Cover list.")
                                .font(.caption)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Display Size") {
                            Text(appState.settings.displayDensity.title)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }

                        Slider(value: displayDensityValue, in: 0...3, step: 1)

                        HStack {
                            ForEach(ActualistDisplayDensity.allCases) { density in
                                Text(density.title)
                                    .font(.caption2.weight(density == appState.settings.displayDensity ? .bold : .medium))
                                    .foregroundStyle(
                                        density == appState.settings.displayDensity
                                            ? ActualistTheme.primaryText
                                            : ActualistTheme.secondaryText
                                    )

                                if density != ActualistDisplayDensity.allCases.last {
                                    Spacer(minLength: 8)
                                }
                            }
                        }
                    }

                    Button {
                        isAppIconPickerPresented = true
                    } label: {
                        LabeledContent {
                            HStack(spacing: 8) {
                                Text(viewModel.selectedAppIcon.title)
                                    .foregroundStyle(ActualistTheme.secondaryText)
                                AppIconThumbnail(icon: viewModel.selectedAppIcon, size: 28)
                            }
                        } label: {
                            Text("App Icon")
                                .foregroundStyle(ActualistTheme.primaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.supportsAlternateIcons)

                    Button {
                        isAccountOrderPresented = true
                    } label: {
                        LabeledContent {
                            HStack(spacing: 8) {
                                Text(accountOrderDetail)
                                    .foregroundStyle(ActualistTheme.secondaryText)
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(ActualistTheme.accent)
                            }
                        } label: {
                            Text("Account Order")
                                .foregroundStyle(ActualistTheme.primaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.settings.selectedBudgetID == nil)

                    Menu {
                        Button {
                            appState.setDefaultAccountID(nil, budgetID: appState.settings.selectedBudgetID ?? "")
                        } label: {
                            if defaultAccountID == nil {
                                Label("First in Order", systemImage: "checkmark")
                            } else {
                                Text("First in Order")
                            }
                        }

                        ForEach(availableAccounts) { account in
                            Button {
                                appState.setDefaultAccountID(account.id, budgetID: appState.settings.selectedBudgetID ?? "")
                            } label: {
                                if defaultAccountID == account.id {
                                    Label(account.name, systemImage: "checkmark")
                                } else {
                                    Text(account.name)
                                }
                            }
                        }
                    } label: {
                        LabeledContent {
                            HStack(spacing: 8) {
                                Text(defaultAccountDetail)
                                    .foregroundStyle(ActualistTheme.secondaryText)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(ActualistTheme.secondaryText)
                            }
                        } label: {
                            Text("Default Account")
                                .foregroundStyle(ActualistTheme.primaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.settings.selectedBudgetID == nil || availableAccounts.isEmpty)
                }
                .settingsSectionChrome()

                Section("Reports") {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isReportOrderExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Label("Chart Order", systemImage: "chart.xyaxis.line")
                                .foregroundStyle(ActualistTheme.primaryText)
                            Spacer(minLength: 8)
                            Image(systemName: isReportOrderExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isReportOrderExpanded {
                        Text("Drag the handles to change the order of cards on the Reports screen.")
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)

                        ForEach(appState.settings.reportCardOrder) { reportCard in
                            Label(reportCard.title, systemImage: reportCard.symbolName)
                                .foregroundStyle(ActualistTheme.primaryText)
                        }
                        .onMove(perform: moveReportCards)

                        Button {
                            appState.resetReportCardOrder()
                        } label: {
                            SettingsActionLabel(
                                title: "Reset Report Order",
                                systemImage: "arrow.counterclockwise"
                            )
                        }
                        .disabled(
                            appState.settings.reportCardOrder == ReportCardOrderPreference.defaultOrder
                        )
                    }
                }
                .settingsSectionChrome()

                Section("Experimental Features") {
                    Label {
                        Text("Experimental features are unfinished and may break or corrupt your budget. Enable them only if you accept that risk.")
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ActualistTheme.warning)
                    }

                    ForEach(ExperimentalFeature.allCases) { feature in
                        Toggle(isOn: experimentalFeatureSelection(feature)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.title)
                                    .foregroundStyle(ActualistTheme.primaryText)
                                Text(feature.detail)
                                    .font(.caption)
                                    .foregroundStyle(ActualistTheme.secondaryText)
                            }
                        }
                    }
                }
                .settingsSectionChrome()

                if appState.settings.developerModeUnlocked {
                    Section("Developer") {
                        Button {
                            isDeveloperDiagnosticsPresented = true
                        } label: {
                            SettingsActionLabel(title: "Developer", systemImage: "wrench.and.screwdriver")
                        }
                    }
                    .settingsSectionChrome()
                }

                Section {
                    Text("Actualist is in beta. If something goes wrong, include a diagnostic report with your bug report so the app, sync, and background state can be investigated.")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)

                    ShareLink(
                        item: ActualistDiagnosticReportBuilder.make(appState: appState),
                        preview: SharePreview(
                            "Actualist Diagnostic Report",
                            image: Image(systemName: "doc.text")
                        )
                    ) {
                        SettingsActionLabel(
                            title: "Share Diagnostic Report",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            appState.beginAppInitiatedSystemUIPresentation()
                        }
                    )

                    Button {
                        viewModel.copyDiagnosticReport(using: appState)
                        diagnosticReportCopied = true
                    } label: {
                        SettingsActionLabel(
                            title: diagnosticReportCopied ? "Diagnostic Report Copied" : "Copy Diagnostic Report",
                            systemImage: diagnosticReportCopied ? "checkmark" : "doc.on.doc"
                        )
                    }

                    Link(destination: Self.newIssueURL) {
                        SettingsActionLabel(title: "Submit a Bug Report", systemImage: "ladybug")
                    }

                    Link(destination: Self.privacyPolicyURL) {
                        SettingsActionLabel(title: "Privacy Policy", systemImage: "hand.raised")
                    }

                    NavigationLink {
                        OpenSourceLicensesView()
                    } label: {
                        SettingsActionLabel(title: "Open Source Licenses", systemImage: "doc.text")
                    }

                    Label {
                        Text("Reports exclude credentials, server addresses, identifiers, names, budget contents, transaction details, and financial amounts.")
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(ActualistTheme.positive)
                    }
                } header: {
                    Text("Support")
                } footer: {
                    Text(appVersionText)
                        .font(.caption2)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .environment(
                \.editMode,
                .constant(isReportOrderExpanded ? .active : .inactive)
            )
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
            .onAppear {
                viewModel.hydrate(from: appState)
            }
            .refreshable {
                await syncNow()
            }
            .onDisappear {
                developerUnlockToastTask?.cancel()
                viewModel.commitFallbackServerURL(using: appState)
            }
            .confirmationDialog(
                "Reimport Budget?",
                isPresented: $isReimportConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Reimport", role: .destructive) {
                    Task { await reimport() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(reimportConfirmationMessage)
            }
            .confirmationDialog(
                "Disconnect & Erase Local Data?",
                isPresented: $isEraseLocalDataConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Disconnect & Erase", role: .destructive) {
                    eraseLocalData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(eraseLocalDataConfirmationMessage)
            }
            .sheet(isPresented: $isBudgetPickerPresented) {
                SettingsBudgetPickerSheet(
                    viewModel: viewModel,
                    isPresented: $isBudgetPickerPresented
                )
                .environment(appState)
            }
            .sheet(isPresented: $isAppIconPickerPresented) {
                AppIconPickerSheet(
                    viewModel: viewModel,
                    recordDeveloperUnlockTap: recordDeveloperUnlockTap
                )
                    .environment(appState)
                    .presentationDetents([.height(320)])
                    .appSwitcherPrivacyAwareDragIndicator()
            }
            .sheet(isPresented: $isAccountOrderPresented) {
                SettingsAccountOrderSheet()
                    .environment(appState)
                    .presentationDetents([.medium, .large])
                    .appSwitcherPrivacyAwareDragIndicator()
            }
            .sheet(isPresented: $isDeveloperDiagnosticsPresented) {
                #if DEBUG
                SettingsDeveloperDiagnosticsSheet(
                    randomizedDisplayValuesSelection: randomizedDisplayValuesSelection,
                    hideDeveloperMode: hideDeveloperMode,
                    debug: appState.settings.backgroundRefreshDebug,
                    syncStatus: appState.localFirstSyncStatus,
                    syncDebug: appState.settings.localFirstSyncDebug,
                    retryPendingSync: appState.retryPendingLocalFirstSync,
                    isPostingDebugNotification: $isPostingDebugNotification,
                    debugNotificationMessage: $debugNotificationMessage,
                    postDebugNotification: postDebugNotification
                )
                #else
                SettingsDeveloperDiagnosticsSheet(
                    randomizedDisplayValuesSelection: randomizedDisplayValuesSelection,
                    hideDeveloperMode: hideDeveloperMode,
                    debug: appState.settings.backgroundRefreshDebug,
                    syncStatus: appState.localFirstSyncStatus,
                    syncDebug: appState.settings.localFirstSyncDebug,
                    retryPendingSync: appState.retryPendingLocalFirstSync
                )
                #endif
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

    private var displayDensityValue: Binding<Double> {
        Binding {
            appState.settings.displayDensity.sliderValue
        } set: { value in
            appState.updateDisplayDensity(ActualistDisplayDensity(sliderValue: value))
        }
    }

    private var themeSelection: Binding<ActualistThemeOption> {
        Binding {
            appState.settings.theme
        } set: { theme in
            appState.updateTheme(theme)
        }
    }

    private var greenIncomeTransactionAmountsSelection: Binding<Bool> {
        Binding {
            appState.settings.greenIncomeTransactionAmountsEnabled
        } set: { isEnabled in
            appState.updateGreenIncomeTransactionAmountsEnabled(isEnabled)
        }
    }

    private var includeCarryoverCategoriesInOverspentAlertsSelection: Binding<Bool> {
        Binding {
            appState.settings.includeCarryoverCategoriesInOverspentAlerts
        } set: { isEnabled in
            appState.updateIncludeCarryoverCategoriesInOverspentAlerts(isEnabled)
        }
    }

    private var canSaveConnection: Bool {
        guard !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !viewModel.isTesting else {
            return false
        }

        return !viewModel.actualPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var accountOrderDetail: String {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return "No Budget"
        }

        return appState.settings.accountOrderByBudgetID[budgetID] == nil ? "Actual Order" : "Custom"
    }

    private var defaultAccountID: String? {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return nil
        }
        return appState.defaultAccountID(forBudgetID: budgetID)
    }

    private var availableAccounts: [ActualAccount] {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return []
        }
        let accounts = appState.accountRepository
            .accountDisplays(budgetID: budgetID)
            .map(\.account)
            .filter { !$0.closed }
        return appState.orderedAccounts(accounts, budgetID: budgetID)
    }

    private var defaultAccountDetail: String {
        guard let id = defaultAccountID else {
            return "First in Order"
        }
        return availableAccounts.first(where: { $0.id == id })?.name ?? "First in Order"
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

    private func moveReportCards(from source: IndexSet, to destination: Int) {
        var reportCardOrder = appState.settings.reportCardOrder
        reportCardOrder.move(fromOffsets: source, toOffset: destination)
        appState.updateReportCardOrder(reportCardOrder)
    }

    private var passwordPrompt: String {
        appState.hasSyncCredentials ? "Re-enter to reconnect" : "Required"
    }

    private var selectedBudgetDisplayName: String {
        guard let selectedBudgetName = appState.settings.selectedBudgetName else {
            return "None"
        }

        guard appState.settings.randomizedDisplayValuesEnabled else {
            return selectedBudgetName
        }

        return PrivacyDisplay.name(
            for: .budget,
            seed: appState.settings.selectedBudgetID ?? selectedBudgetName
        )
    }

    private var localFirstLastSyncedText: String {
        guard let lastSyncedAt = appState.localFirstSyncStatus?.lastSyncedAt else {
            return "Unknown"
        }
        return lastSyncedAt.formatted(.relative(presentation: .named))
    }

    private var localFirstPendingSyncText: String {
        let count = appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        if count == 0 {
            return "None"
        }
        return count == 1 ? "1 change" : "\(count) changes"
    }

    private var localFirstPendingSyncForeground: Color {
        let count = appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        return count == 0 ? ActualistTheme.secondaryText : ActualistTheme.warning
    }

    private var localFirstSecurityText: String {
        if appState.localFirstSyncStatus?.encryptionKeyID != nil {
            return "Encrypted · Unlocked"
        }
        return "Not encrypted"
    }

    private var reimportConfirmationMessage: String {
        destructiveLocalDataMessage(
            base: "Actualist will delete the local copy of this budget and download a fresh one from the server."
        )
    }

    private var eraseLocalDataConfirmationMessage: String {
        destructiveLocalDataMessage(
            base: "Actualist will remove the sync token, cached encryption keys, imported budget files, and local selections from this device."
        )
    }

    private func destructiveLocalDataMessage(base: String) -> String {
        let pendingCount = appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        guard pendingCount > 0 else {
            return "\(base) Your server data is not changed."
        }
        let noun = pendingCount == 1 ? "change" : "changes"
        return "\(base) Warning: \(pendingCount) local \(noun) have not been confirmed by the server and will be permanently lost."
    }

    private func syncNow() async {
        guard let budgetID = appState.settings.selectedBudgetID, !isSyncingNow else {
            return
        }
        isSyncingNow = true
        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        isSyncingNow = false
    }

    private func reimport() async {
        guard !isReimporting else {
            return
        }
        isReimporting = true
        await appState.reimportLocalFirstBudget()
        isReimporting = false
    }

    private func eraseLocalData() {
        guard !isErasingLocalData else {
            return
        }
        isErasingLocalData = true
        appState.disconnectAndEraseLocalData()
        viewModel.actualPassword = ""
        viewModel.serverURLString = appState.settings.localFirstServerURLString
        viewModel.fallbackServerURLString = appState.settings.fallbackServerURLString
        isErasingLocalData = false
    }

    private var randomizedDisplayValuesSelection: Binding<Bool> {
        Binding {
            appState.settings.randomizedDisplayValuesEnabled
        } set: { isEnabled in
            appState.updateRandomizedDisplayValuesEnabled(isEnabled)
        }
    }

    private var appSwitcherPrivacyModeSelection: Binding<AppSwitcherPrivacyMode> {
        Binding {
            appState.settings.appSwitcherPrivacyMode
        } set: { mode in
            appState.updateAppSwitcherPrivacyMode(mode)
        }
    }

    private func experimentalFeatureSelection(_ feature: ExperimentalFeature) -> Binding<Bool> {
        Binding {
            appState.isExperimentalFeatureEnabled(feature)
        } set: { isEnabled in
            appState.updateExperimentalFeature(feature, isEnabled: isEnabled)
        }
    }

    private func recordDeveloperUnlockTap() {
        if let message = appState.recordDeveloperUnlockTap() {
            showDeveloperUnlockToast(message)
        }
    }

    private func hideDeveloperMode() {
        appState.updateDeveloperModeUnlocked(false)
        isDeveloperDiagnosticsPresented = false
        showDeveloperUnlockToast("Developer Mode hidden")
    }

    private func showDeveloperUnlockToast(_ message: String) {
        developerUnlockToastTask?.cancel()
        withAnimation(.snappy(duration: 0.2)) {
            appState.developerUnlockToastMessage = message
        }

        developerUnlockToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(SettingsDeveloperUnlock.toastDurationSeconds))
            withAnimation(.snappy(duration: 0.2)) {
                if appState.developerUnlockToastMessage == message {
                    appState.developerUnlockToastMessage = nil
                }
            }
        }
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

    #if DEBUG
    private func postDebugNotification() async {
        isPostingDebugNotification = true
        debugNotificationMessage = nil
        defer { isPostingDebugNotification = false }

        do {
            try await appState.postDebugNewTransactionNotification()
            debugNotificationMessage = "Test alert will post in 5 seconds. Send Actualist to the background, then tap the notification."
        } catch {
            debugNotificationMessage = error.localizedDescription
        }
    }
    #endif
}
