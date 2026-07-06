import SwiftUI

private enum SettingsDeveloperUnlock {
    static let toastDurationSeconds: Double = 1.4
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = SettingsViewModel()
    @State private var isBudgetPickerPresented = false
    @State private var isAppIconPickerPresented = false
    @State private var isAccountOrderPresented = false
    @State private var isDeveloperDiagnosticsPresented = false
    @State private var developerUnlockToastTask: Task<Void, Never>?
    @State private var isSyncingNow = false
    @State private var isReimporting = false
    @State private var isReimportConfirmationPresented = false
    #if DEBUG
    @State private var isPostingDebugNotification = false
    @State private var debugNotificationMessage: String?
    #endif

    var body: some View {
        NavigationStack {
            List {
                settingsHeader

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

                    LabeledContent("Password") {
                        SecureField(passwordPrompt, text: $viewModel.actualPassword)
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }

                    if appState.canUseAPI {
                        Text("Your password is not stored. Actualist keeps a sync token and only needs the password again to reconnect.")
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    SettingsStatusRow(status: appState.connectionStatus)

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
                }
                .settingsSectionChrome()

                Section("Budget") {
                    LabeledContent("Selected") {
                        Text(selectedBudgetDisplayName)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }

                    Button {
                        isBudgetPickerPresented = true
                    } label: {
                        SettingsActionLabel(title: "Change Budget", systemImage: "folder")
                    }

                    if appState.capabilities.isLocalFirst {
                        Button {
                            Task { await syncNow() }
                        } label: {
                            SettingsActionLabel(
                                title: isSyncingNow ? "Syncing" : "Sync Now",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        .disabled(isSyncingNow || appState.settings.selectedBudgetID == nil)

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
                }
                .settingsSectionChrome()

                Section("Background Refresh") {
                    Toggle("New Transaction Alerts", isOn: backgroundRefreshSelection)
                        .disabled(!appState.capabilities.supportsBackgroundRefresh)
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
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                viewModel.hydrate(from: appState)
            }
            .onDisappear {
                developerUnlockToastTask?.cancel()
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
                Text("Actualist will delete the local copy of this budget and download a fresh one from the server. Your server data is not changed.")
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
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isAccountOrderPresented) {
                SettingsAccountOrderSheet()
                    .environment(appState)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isDeveloperDiagnosticsPresented) {
                #if DEBUG
                SettingsDeveloperDiagnosticsSheet(
                    randomizedDisplayValuesSelection: randomizedDisplayValuesSelection,
                    localFirstWritesSelection: localFirstWritesSelection,
                    hideDeveloperMode: hideDeveloperMode,
                    debug: appState.settings.backgroundRefreshDebug,
                    isPostingDebugNotification: $isPostingDebugNotification,
                    debugNotificationMessage: $debugNotificationMessage,
                    postDebugNotification: postDebugNotification
                )
                #else
                SettingsDeveloperDiagnosticsSheet(
                    randomizedDisplayValuesSelection: randomizedDisplayValuesSelection,
                    localFirstWritesSelection: localFirstWritesSelection,
                    hideDeveloperMode: hideDeveloperMode,
                    debug: appState.settings.backgroundRefreshDebug
                )
                #endif
            }
        }
        .overlay(alignment: .bottom) {
            developerUnlockToast
        }
    }

    private var settingsHeader: some View {
        Button {
            recordDeveloperUnlockTap()
        } label: {
            HStack(spacing: 0) {
                Text("Settings")
                    .font(.largeTitle.bold())
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Settings")
        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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

    private var passwordPrompt: String {
        appState.canUseAPI ? "Re-enter to reconnect" : "Required"
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
        guard let status = appState.localFirstSyncStatus, let lastSyncedAt = status.lastSyncedAt else {
            return "Never"
        }
        let relative = lastSyncedAt.formatted(.relative(presentation: .named))
        return "\(relative) · \(status.lastAppliedMessageCount) applied"
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

    private func syncNow() async {
        guard let budgetID = appState.settings.selectedBudgetID, !isSyncingNow else {
            return
        }
        isSyncingNow = true
        await appState.refreshLocalFirstData(budgetID: budgetID)
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

    private var randomizedDisplayValuesSelection: Binding<Bool> {
        Binding {
            appState.settings.randomizedDisplayValuesEnabled
        } set: { isEnabled in
            appState.updateRandomizedDisplayValuesEnabled(isEnabled)
        }
    }

    private var localFirstWritesSelection: Binding<Bool> {
        Binding {
            appState.settings.localFirstWritesEnabled
        } set: { isEnabled in
            appState.updateLocalFirstWritesEnabled(isEnabled)
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
            let accountName = try await appState.postDebugNewTransactionNotification()
            debugNotificationMessage = "Test alert for \(accountName) will post in 5 seconds. Send Actualist to the background, then tap the notification."
        } catch {
            debugNotificationMessage = error.localizedDescription
        }
    }
    #endif
}

private struct SettingsDeveloperDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var randomizedDisplayValuesSelection: Bool
    @Binding var localFirstWritesSelection: Bool
    let hideDeveloperMode: () -> Void
    let debug: BackgroundRefreshDebugInfo
    #if DEBUG
    @Binding var isPostingDebugNotification: Bool
    @Binding var debugNotificationMessage: String?
    let postDebugNotification: () async -> Void
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy") {
                    Toggle("Generic Screenshot Data", isOn: $randomizedDisplayValuesSelection)
                }
                .settingsSectionChrome()

                Section("Local-First Writes") {
                    Toggle("Write Testing", isOn: $localFirstWritesSelection)

                    Text("Enables local-first write proofs for fake-budget testing: transactions, category budget assignment, and move money. Templates, rules, and account writes stay disabled.")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()

                #if DEBUG
                Section("Notifications") {
                    Button {
                        Task { await postDebugNotification() }
                    } label: {
                        SettingsActionLabel(
                            title: isPostingDebugNotification ? "Posting Test Alert" : "Post Test Transaction Alert",
                            systemImage: "bell.badge"
                        )
                    }
                    .disabled(isPostingDebugNotification)

                    if let debugNotificationMessage {
                        Text(debugNotificationMessage)
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                }
                .settingsSectionChrome()
                #endif

                Section("Background Refresh Logs") {
                    BackgroundRefreshDebugRows(debug: debug)
                }
                .settingsSectionChrome()

                Section("Developer Mode") {
                    Button(role: .destructive) {
                        hideDeveloperMode()
                    } label: {
                        SettingsActionLabel(title: "Hide Developer Mode", systemImage: "eye.slash")
                    }
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SettingsActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(ActualistTheme.primaryText)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(ActualistTheme.accent)
        }
    }
}

private struct SettingsStatusRow: View {
    let status: ServerConnectionStatus

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.45), radius: 4)

                Text(title)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
    }

    private var title: String {
        switch status {
        case .online:
            "Connected"
        case .connecting:
            "Checking"
        case .offline:
            "Offline"
        }
    }

    private var color: Color {
        switch status {
        case .online:
            ActualistTheme.positive
        case .connecting:
            ActualistTheme.warning
        case .offline:
            ActualistTheme.danger
        }
    }
}

private struct BackgroundRefreshDebugRows: View {
    let debug: BackgroundRefreshDebugInfo

    var body: some View {
        LabeledContent("Schedule Count") {
            Text(debug.scheduleAttemptCount.formatted())
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        if debug.recentScheduleAttempts.isEmpty {
            Text("No schedule attempts yet")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            ForEach(debug.recentScheduleAttempts.prefix(5)) { attempt in
                BackgroundRefreshScheduleAttemptRow(attempt: attempt)
            }
        }

        LabeledContent("Wake Count") {
            Text(debug.wakeCount.formatted())
                .foregroundStyle(ActualistTheme.secondaryText)
        }

        if debug.recentRuns.isEmpty {
            Text("No background wakes yet")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            ForEach(debug.recentRuns.prefix(20)) { run in
                BackgroundRefreshDebugRunRow(run: run)
            }
        }
    }
}

private struct BackgroundRefreshScheduleAttemptRow: View {
    let attempt: BackgroundRefreshScheduleAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formattedDate(attempt.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer(minLength: 8)

                Text(attempt.succeeded ? "Accepted" : "Rejected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(attempt.succeeded ? ActualistTheme.positive : ActualistTheme.danger)
            }

            if let earliestBeginDate = attempt.earliestBeginDate {
                Text("Earliest \(formattedDate(earliestBeginDate))")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            Text(attempt.message)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else {
            return "Not yet"
        }

        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }
}

private struct BackgroundRefreshDebugRunRow: View {
    let run: BackgroundRefreshDebugRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formattedDate(run.wakeDate))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer(minLength: 8)

                Text(resultText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resultColor)
            }

            if let completionDate = run.completionDate {
                Text("Finished \(formattedDate(completionDate))")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            Text(run.message)
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .lineLimit(4)
        }
        .padding(.vertical, 2)
    }

    private var resultText: String {
        guard let succeeded = run.succeeded else {
            return "Started"
        }

        return succeeded ? "Succeeded" : "Failed"
    }

    private var resultColor: Color {
        switch run.succeeded {
        case true:
            ActualistTheme.positive
        case false:
            ActualistTheme.danger
        case nil:
            ActualistTheme.secondaryText
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else {
            return "Not yet"
        }

        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }
}

private struct SettingsBudgetPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: SettingsViewModel
    @Binding var isPresented: Bool
    @State private var encryptedBudgetPrompt: ActualBudget?
    @State private var encryptionPassword = ""
    @State private var isUnlockingEncryptedBudget = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isLoadingBudgets {
                    ProgressView("Loading budgets")
                        .settingsRowChrome()
                }

                if let message = appState.lastErrorMessage {
                    Text(message)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.danger)
                        .settingsRowChrome()
                }

                Section("Choose Budget") {
                    ForEach(appState.budgets) { budget in
                        Button {
                            Task { await selectBudget(budget) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(budgetDisplayName(budget))
                                        .font(ActualistTypography.rowTitle(for: density))
                                        .foregroundStyle(ActualistTheme.primaryText)
                                    if !appState.settings.randomizedDisplayValuesEnabled {
                                        Text(budget.syncID)
                                            .font(ActualistTypography.rowLabel(for: density))
                                            .foregroundStyle(ActualistTheme.secondaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }

                                Spacer()

                                if appState.settings.selectedBudgetID == budget.syncID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(ActualistTheme.accent)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(ActualistTheme.secondaryText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Budgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.loadBudgetsForSelection(using: appState) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.body.weight(.semibold))
                    .controlSize(.small)
                    .disabled(viewModel.isLoadingBudgets)
                }
            }
            .task {
                await viewModel.loadBudgetsForSelection(using: appState)
            }
            .sheet(item: $encryptedBudgetPrompt) { budget in
                NavigationStack {
                    Form {
                        Section {
                            SecureField("Encryption Password", text: $encryptionPassword)
                                .textInputAutocapitalization(.never)
                                .textContentType(.password)
                        } footer: {
                            Text("Enter this budget's encryption password. Actualist stores the unlocked budget key in Keychain, not this password.")
                        }

                        if let message = appState.lastErrorMessage,
                           message != LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription {
                            Section {
                                Text(message)
                                    .font(ActualistTypography.rowTitle(for: density))
                                    .foregroundStyle(ActualistTheme.danger)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(ActualistTheme.background)
                    .foregroundStyle(ActualistTheme.primaryText)
                    .tint(ActualistTheme.accent)
                    .navigationTitle("Unlock Budget")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                encryptedBudgetPrompt = nil
                                encryptionPassword = ""
                            }
                        }

                        ToolbarItem(placement: .confirmationAction) {
                            Button(isUnlockingEncryptedBudget ? "Unlocking" : "Unlock") {
                                Task { await unlockBudget(budget) }
                            }
                            .disabled(encryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUnlockingEncryptedBudget)
                        }
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func selectBudget(_ budget: ActualBudget) async {
        await appState.selectBudgetForCurrentBackend(budget)
        if appState.lastErrorMessage == LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription {
            encryptedBudgetPrompt = budget
            return
        }

        if appState.settings.selectedBudgetID == budget.syncID {
            isPresented = false
        }
    }

    private func unlockBudget(_ budget: ActualBudget) async {
        guard !isUnlockingEncryptedBudget else {
            return
        }

        isUnlockingEncryptedBudget = true
        await appState.selectBudgetForCurrentBackend(
            budget,
            encryptionPassword: encryptionPassword
        )
        isUnlockingEncryptedBudget = false

        if appState.settings.selectedBudgetID == budget.syncID {
            encryptedBudgetPrompt = nil
            encryptionPassword = ""
            isPresented = false
        }
    }

    private func budgetDisplayName(_ budget: ActualBudget) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return budget.name
        }

        return PrivacyDisplay.name(for: .budget, seed: budget.syncID)
    }
}

private struct SettingsAccountOrderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss

    @State private var accounts: [ActualAccount] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView("Loading accounts")
                        .settingsRowChrome()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.danger)
                        .settingsRowChrome()
                }

                Section("Accounts") {
                    if appState.settings.selectedBudgetID == nil {
                        Text("Select a budget before setting account order.")
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } else if accounts.isEmpty && !isLoading {
                        Text("No accounts loaded.")
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    } else {
                        ForEach(accounts) { account in
                            SettingsAccountOrderRow(account: account)
                        }
                        .onMove(perform: moveAccounts)
                    }
                }
                .settingsSectionChrome()
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Account Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        resetOrder()
                    }
                    .disabled(!hasCustomOrder)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadAccounts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.body.weight(.semibold))
                    .controlSize(.small)
                    .disabled(isLoading || appState.settings.selectedBudgetID == nil)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadAccounts()
            }
        }
    }

    private var hasCustomOrder: Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        return appState.settings.accountOrderByBudgetID[budgetID] != nil
    }

    private func loadAccounts() async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            accounts = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            guard let repository = appState.makeAccountRepository() else {
                accounts = []
                isLoading = false
                return
            }
            try await repository.refreshAccountsWithBalances(budgetID: budgetID)
        } catch {
            errorMessage = appState.makeAccountRepository()?.accountDisplays(budgetID: budgetID).isEmpty == false
                ? "Could not refresh accounts. Showing cached accounts."
                : error.localizedDescription
        }

        let loadedAccounts = appState.makeAccountRepository()?.accountDisplays(budgetID: budgetID).map(\.account) ?? []
        accounts = appState.orderedAccounts(loadedAccounts, budgetID: budgetID)
        isLoading = false
    }

    private func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        persistOrder()
    }

    private func persistOrder() {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }

        appState.updateAccountOrder(accounts.map(\.id), budgetID: budgetID)
    }

    private func resetOrder() {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }

        appState.resetAccountOrder(budgetID: budgetID)
        accounts = appState.makeAccountRepository()?.accountDisplays(budgetID: budgetID).map(\.account) ?? accounts
    }
}

private struct SettingsAccountOrderRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density

    let account: ActualAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.offbudget ? "tray.full.fill" : "banknote.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.accent)
                .frame(width: density.iconSize, height: density.iconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                if let detail {
                    Text(detail)
                        .font(ActualistTypography.rowLabel(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return account.name
        }

        return PrivacyDisplay.name(for: .account, seed: account.id)
    }

    private var detail: String? {
        if account.closed {
            return "Closed"
        }
        if account.offbudget {
            return "Off Budget"
        }
        return nil
    }
}

private struct ThemePreviewStrip: View {
    let theme: ActualistThemeOption

    var body: some View {
        let palette = ActualistTheme.palette(for: theme)

        HStack(spacing: 8) {
            ThemeSwatch(color: palette.background)
            ThemeSwatch(color: palette.surface)
            ThemeSwatch(color: palette.elevatedSurface)
            ThemeSwatch(color: palette.accent)
            ThemeSwatch(color: palette.positive)
            ThemeSwatch(color: palette.warning)
            ThemeSwatch(color: palette.danger)
            ThemeSwatch(color: palette.neutral)
        }
        .padding(.vertical, 4)
    }
}

private struct AppIconPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SettingsViewModel
    let recordDeveloperUnlockTap: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AppIcon.allCases) { icon in
                        Button {
                            recordDeveloperUnlockTap()
                            Task { await viewModel.setAppIcon(icon) }
                        } label: {
                            AppIconChoice(
                                icon: icon,
                                isSelected: viewModel.selectedAppIcon == icon
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let error = viewModel.appIconError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ActualistTheme.background)
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AppIconChoice: View {
    let icon: AppIcon
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            AppIconThumbnail(icon: icon, size: 72)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected ? ActualistTheme.accent : .clear,
                            lineWidth: 3
                        )
                }

            Text(icon.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? ActualistTheme.primaryText : ActualistTheme.secondaryText)
        }
    }
}

private struct AppIconThumbnail: View {
    let icon: AppIcon
    let size: CGFloat

    var body: some View {
        let radius = size * 0.2237

        Group {
            if let image = UIImage(named: icon.previewImageName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(ActualistTheme.elevatedSurface)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private extension View {
    func settingsSectionChrome() -> some View {
        self
            .listRowBackground(ActualistTheme.surface)
            .listRowSeparatorTint(ActualistTheme.separator)
    }

    func settingsRowChrome() -> some View {
        self
            .listRowBackground(ActualistTheme.surface)
            .listRowSeparatorTint(ActualistTheme.separator)
    }
}

private struct ThemeSwatch: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
    }
}
