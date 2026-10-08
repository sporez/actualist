import SwiftUI

/// Settings → Budget & Data → Bank Sync (plan Phase 4, Settings-only MVP).
/// Layout and bindings only: state, copy, and write coordination live in
/// `BankSyncViewModel` and the store.
struct BankSyncView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: BankSyncViewModel?

    var body: some View {
        Group {
            if let viewModel {
                BankSyncScreen(viewModel: viewModel, isDemoMode: appState.isDemoMode)
            } else {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Bank Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else {
                return
            }
            guard let budgetID = appState.settings.selectedBudgetID else {
                return
            }
            let currency = appState.localFirstStore.budgetCurrency(budgetID: budgetID)
            let model = BankSyncViewModel(
                store: appState.localFirstStore,
                budgetID: budgetID,
                currency: currency,
                isDemoMode: appState.isDemoMode
            )
            viewModel = model
            await model.load()
        }
    }
}

private struct BankSyncScreen: View {
    @Environment(AppState.self) private var appState
    @State var viewModel: BankSyncViewModel
    @State private var isWalletPickerPresented = false
    let isDemoMode: Bool

    var body: some View {
        List {
            serverSection
            if !isDemoMode, viewModel.serverSupport != .configured {
                deviceTokenSection
                    .disabled(viewModel.isSyncing)
            }
            backgroundSyncSection
            if WalletImportAvailability.isFinancialDataAvailable {
                WalletImportSettingsSection(isWalletPickerPresented: $isWalletPickerPresented)
            }
            accountsSection
            if !viewModel.resultLines.isEmpty {
                Section("Sync Results") {
                    ForEach(viewModel.resultLines) { line in
                        BankSyncResultRow(line: line)
                    }
                }
                .settingsSectionChrome()
            }
        }
        .sheet(item: Binding(
            get: { viewModel.selectedLine },
            set: { line in
                if line == nil {
                    viewModel.dismissAccountSheet()
                }
            }
        )) { line in
            BankSyncAccountSheet(viewModel: viewModel, line: line)
                .environment(appState)
        }
        .walletImportPresentation(isPickerPresented: $isWalletPickerPresented)
    }

    private var serverSection: some View {
        Section {
            LabeledContent("Provider") {
                Text(BankSyncCopy.providerText(
                    support: viewModel.serverSupport,
                    hasDeviceKey: viewModel.hasDeviceKey,
                    isDemoMode: isDemoMode
                ))
                .foregroundStyle(ActualistTheme.secondaryText)
                .multilineTextAlignment(.trailing)
            }

            if let lastRun = viewModel.lastRun {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Last result")
                        Spacer(minLength: 8)
                        if let caption = viewModel.lastRunCaption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }
                    Text(lastRun.summary)
                        .font(.subheadline)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            if case .failed(let message) = viewModel.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.danger)
            }

            Button {
                Task { await viewModel.syncAll() }
            } label: {
                HStack {
                    SettingsActionLabel(
                        title: viewModel.syncButtonTitle,
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    if viewModel.isSyncing { ProgressView() }
                }
            }
            .disabled(!viewModel.canSyncAll)
        } header: {
            Text("Bank Connection")
        } footer: {
            if let footer = BankSyncCopy.connectionFooter(
                support: viewModel.serverSupport,
                hasDeviceKey: viewModel.hasDeviceKey,
                isDemoMode: isDemoMode
            ) {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .settingsSectionChrome()
    }

    private var backgroundSyncSection: some View {
        Section {
            Toggle("Background Bank Sync", isOn: backgroundSyncSelection)
                .disabled(isDemoMode || viewModel.serverSupport != .configured)
        } header: {
            Text("Background Sync")
        } footer: {
            Text(BankSyncCopy.backgroundSyncFooter(
                support: viewModel.serverSupport,
                phase: viewModel.phase,
                isDemoMode: isDemoMode
            ))
            .font(.caption)
            .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }

    private var backgroundSyncSelection: Binding<Bool> {
        Binding {
            appState.settings.simplefinBackgroundSyncEnabled
        } set: { isEnabled in
            Task {
                await appState.updateSimpleFINBackgroundSyncEnabled(isEnabled)
            }
        }
    }

    private var deviceTokenSection: some View {
        Section {
            if viewModel.hasDeviceKey {
                Button(role: .destructive) {
                    Task { await viewModel.forgetDeviceKey() }
                } label: {
                    SettingsActionLabel(
                        title: "Disconnect",
                        systemImage: "minus.circle"
                    )
                }
            } else {
                TextField("Paste setup token", text: $viewModel.draftSetupToken, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await viewModel.claimDeviceToken() }
                } label: {
                    SettingsActionLabel(
                        title: viewModel.isClaiming ? "Connecting…" : "Connect",
                        systemImage: "link"
                    )
                }
                .disabled(!viewModel.canClaimDeviceToken)
            }
        } header: {
            Text("SimpleFIN Token")
        } footer: {
            Text("Paste a one-time setup token from SimpleFIN. It is claimed once and the access key is stored only on this device.")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }

    private var accountsSection: some View {
        Section {
            if viewModel.accountLines.isEmpty {
                Text(viewModel.phase == .loading ? "Loading accounts…" : "No accounts in this budget.")
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            ForEach(viewModel.accountLines) { line in
                Button {
                    viewModel.selectAccount(line.id)
                } label: {
                    BankSyncAccountRow(line: line)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSyncing)
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Tap an account to link it to a bank account or unlink it.")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .settingsSectionChrome()
    }
}

private struct BankSyncAccountRow: View {
    let line: BankSyncViewModel.AccountLine

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .foregroundStyle(ActualistTheme.primaryText)
                Text(line.lastSyncText)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            Spacer()
            if let statusText = line.statusText {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dotColor)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .contentShape(Rectangle())
    }

    private var dotColor: Color {
        switch line.statusColorKind {
        case .healthy: return ActualistTheme.positive
        case .pending: return ActualistTheme.warning
        case .failed: return ActualistTheme.danger
        case .none: return ActualistTheme.secondaryText
        }
    }
}
