import SwiftUI

/// Budget & Data settings: selected budget, change budget, payees, encryption
/// status, reimport, portable export, Bank Sync, default account, and account
/// order.
struct BudgetDataSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var viewModel = SettingsViewModel()
    @State private var carryoverViewModel = BulkCategoryCarryoverViewModel()
    @State private var isBudgetPickerPresented = false
    @State private var isAccountOrderPresented = false
    @State private var isReimporting = false
    @State private var exportWorkflow = PortableBudgetExportWorkflow()
    @State private var isReimportConfirmationPresented = false
    @State private var isReimportPasswordPresented = false
    @State private var reimportPassword = ""
    @State private var isCarryoverConfirmationPresented = false

    var body: some View {
        List {
            Section {
                LabeledContent("Selected") {
                    Text(selectedBudgetDisplayName)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }

                LabeledContent("Security") {
                    Text(securityText)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }

                Button {
                    isBudgetPickerPresented = true
                } label: {
                    SettingsActionLabel(title: "Change Budget", systemImage: "folder")
                }

                NavigationLink {
                    PayeesView()
                } label: {
                    SettingsActionLabel(title: "Payees", systemImage: "person.2")
                }
                .disabled(appState.settings.selectedBudgetID == nil)

                NavigationLink {
                    BudgetRulesView()
                } label: {
                    SettingsActionLabel(title: "Rules", systemImage: "wand.and.stars")
                }
                .disabled(appState.settings.selectedBudgetID == nil)

                NavigationLink {
                    BankSyncView()
                } label: {
                    SettingsActionLabel(title: "Bank Sync", systemImage: "building.columns")
                }
                .disabled(appState.settings.selectedBudgetID == nil)

                Toggle(isOn: allCategoriesCarryoverSelection) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rollover All Overspending")
                        Text(carryoverControlDetail)
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                }
                .disabled(isCarryoverControlDisabled)
                .confirmationDialog(
                    "Set Rollover for All Categories?",
                    isPresented: $isCarryoverConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Turn On for All") {
                        applyCarryoverToAllCategories(true)
                    }
                    .tint(ActualistTheme.primaryText)
                    .disabled(carryoverViewModel.status?.canEnableAll != true)

                    Button("Turn Off for All", role: .destructive) {
                        applyCarryoverToAllCategories(false)
                    }
                    .disabled(carryoverViewModel.status?.canDisableAll != true)

                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(carryoverConfirmationMessage)
                }

                if let errorMessage = carryoverViewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                }
            } header: {
                Text("Budget")
            } footer: {
                Text("Applies from the current month forward to every expense category, including hidden categories.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()

            if !appState.isDemoMode {
                Section {
                    Button(role: .destructive) {
                        isReimportConfirmationPresented = true
                    } label: {
                        SettingsActionLabel(
                            title: isReimporting ? "Reimporting" : "Reimport Budget",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(isReimporting || appState.settings.selectedBudgetID == nil)
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
                } header: {
                    Text("Data")
                } footer: {
                    Text("Deletes the local copy of this budget and downloads a fresh one from the server.")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()
            }

            exportSection

            Section("Accounts") {
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
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Budget & Data")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.hydrate(from: appState)
        }
        // The share ZIP is built for the open budget when the screen opens and
        // discarded when it goes away. It is not rebuilt on background data
        // changes: that would delete a file a share sheet may still be reading.
        .task(id: appState.settings.selectedBudgetID) {
            prepareExport()
        }
        .onDisappear { exportWorkflow.reset() }
        .task(id: appState.settings.selectedBudgetID) {
            isCarryoverConfirmationPresented = false
            guard let budgetID = appState.settings.selectedBudgetID else {
                carryoverViewModel.reset()
                return
            }
            await carryoverViewModel.load(
                budgetID: budgetID,
                preferredMonth: YearMonth(date: Date()).rawValue,
                repository: appState.budgetRepository
            )
        }
        .sheet(isPresented: $isBudgetPickerPresented) {
            SettingsBudgetPickerSheet(
                viewModel: viewModel,
                isPresented: $isBudgetPickerPresented
            )
            .environment(appState)
        }
        .sheet(isPresented: $isAccountOrderPresented) {
            SettingsAccountOrderSheet()
                .environment(appState)
        }
        .alert("Encryption Password", isPresented: $isReimportPasswordPresented) {
            SecureField("Encryption password", text: $reimportPassword)
            Button("Unlock") {
                let password = reimportPassword
                reimportPassword = ""
                Task { await reimport(encryptionPassword: password) }
            }
            Button("Cancel", role: .cancel) { reimportPassword = "" }
        } message: {
            Text("This budget's encryption settings changed on the server. Enter its current encryption password to download it again.")
        }
    }

    /// Export is non-destructive and stays its own section, visually and
    /// semantically separate from the destructive Reimport row above. The ZIP
    /// is built when the screen opens, so the row is one tap on a ready file
    /// (`PortableBudgetExportWorkflow`).
    @ViewBuilder
    private var exportSection: some View {
        Section {
            if let budgetID = appState.settings.selectedBudgetID,
               let archiveURL = exportWorkflow.readyArchive(for: budgetID) {
                ShareLink(
                    item: archiveURL,
                    preview: SharePreview("Budget Export", image: Image(systemName: "doc.zipper"))
                ) {
                    exportRowLabel
                }
                .accessibilityIdentifier("budget-export-share")
            } else {
                exportRowLabel
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .accessibilityIdentifier("budget-export-share")
            }
            if case .failed(let message) = exportWorkflow.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
                Button("Try Again") { prepareExport() }
                    .accessibilityIdentifier("budget-export-retry")
            }
        } header: {
            Text("Export")
        } footer: {
            Text(PortableBudgetExportWorkflow.footerText(
                isBudgetEncrypted: appState.localFirstStore.isOpenBudgetEncrypted
            ))
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }

    private func prepareExport() {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        Task {
            await exportWorkflow.prepare(budgetID: budgetID) { budgetID in
                try await appState.localFirstStore.exportPortableBudgetArchive(budgetID: budgetID)
            }
        }
    }

    private var exportRowLabel: some View {
        SettingsActionLabel(
            title: "Share Budget ZIP…",
            systemImage: "square.and.arrow.up",
            isBusy: exportWorkflow.isPreparing
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var allCategoriesCarryoverSelection: Binding<Bool> {
        Binding {
            carryoverViewModel.status?.allEnabled == true
        } set: { _ in
            isCarryoverConfirmationPresented = true
        }
    }

    private var carryoverControlDetail: String {
        if carryoverViewModel.isApplying {
            return "Updating all categories…"
        }
        if carryoverViewModel.isLoading, carryoverViewModel.status == nil {
            return "Loading categories…"
        }
        return carryoverViewModel.status?.detail ?? "Unavailable"
    }

    private var isCarryoverControlDisabled: Bool {
        carryoverViewModel.isLoading
            || carryoverViewModel.isApplying
            || carryoverViewModel.status?.categoryCount == 0
            || appState.settings.selectedBudgetID == nil
    }

    private var carryoverConfirmationMessage: String {
        guard let status = carryoverViewModel.status else {
            return "Choose whether every expense category should roll overspending into the next month."
        }
        return "Changes \(status.categoryCount) expense categories from \(status.monthTitle) forward, including hidden categories. Existing transactions and assignments are not deleted."
    }

    private func applyCarryoverToAllCategories(_ enabled: Bool) {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        Task {
            await carryoverViewModel.setAll(
                carryover: enabled,
                budgetID: budgetID,
                repository: appState.budgetRepository
            )
        }
    }

    private var selectedBudgetDisplayName: String {
        PrivacyDisplay.selectedBudgetName(
            name: appState.settings.selectedBudgetName,
            id: appState.settings.selectedBudgetID,
            randomized: appState.settings.randomizedDisplayValuesEnabled
        )
    }

    private var securityText: String {
        if appState.localFirstSyncStatus?.encryptionKeyID != nil {
            return "Encrypted · Unlocked"
        }
        return "Not encrypted"
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

    private var reimportConfirmationMessage: String {
        let base = "Actualist will delete the local copy of this budget and download a fresh one from the server."
        return LocalDataLossWarning.message(
            base: base,
            pendingChangeCount: appState.localFirstSyncStatus?.pendingLocalMessageCount ?? 0
        )
    }

    private func reimport(encryptionPassword: String? = nil) async {
        guard !isReimporting else {
            return
        }
        isReimporting = true
        let outcome = await appState.reimportLocalFirstBudget(encryptionPassword: encryptionPassword)
        isReimporting = false
        if outcome == .opened { ActualistHaptics.success() }

        guard outcome == .needsEncryptionPassword else {
            return
        }
        reimportPassword = ""
        isReimportPasswordPresented = true
    }
}
