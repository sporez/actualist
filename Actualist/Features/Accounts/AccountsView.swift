import SwiftUI

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var expandedSections: Set<AccountSectionKind> = [.budget, .offBudget]
    @State private var isAddAccountPresented = false
    @State private var addAccountViewModel = AddAccountViewModel()

    /// Reactive snapshot from the shared store: shows cached balances instantly and updates
    /// as the background refresh lands.
    private var accounts: [AccountDisplay] {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return []
        }
        guard let repository = appState.makeAccountRepository() else {
            return []
        }
        return appState.orderedAccountDisplays(
            repository.accountDisplays(budgetID: budgetID),
            budgetID: budgetID
        )
    }

    var body: some View {
        NavigationStack(path: accountNavigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    accountSection(kind: .budget, title: "Budget Accounts", rows: openBudgetAccounts)
                    accountSection(kind: .offBudget, title: "Off Budget", rows: offBudgetAccounts)
                    accountSection(
                        kind: .closed,
                        title: "Closed",
                        rows: closedAccounts
                    )

                    if appState.capabilities.showsAddAccount {
                        Button {
                            isAddAccountPresented = true
                        } label: {
                            Label("Add Account", systemImage: "plus.circle")
                                .font(ActualistTypography.control(for: density))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .tint(ActualistTheme.accent)
                        .disabled(!appState.capabilities.canAddAccount)
                        .padding(.top, 8)
                    }

                    if isLoading && accounts.isEmpty {
                        AccountsLoadingView()
                            .padding(.vertical, 48)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(ActualistTheme.background)
            .navigationTitle("Accounts")
            .navigationDestination(for: ActualAccount.self) { account in
                AccountTransactionsView(account: account)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .actualistToolbarGlassButton()
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $isAddAccountPresented) {
                AddAccountSheet(viewModel: addAccountViewModel)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var openBudgetAccounts: [AccountDisplay] {
        accounts.filter { !$0.account.closed && !$0.account.offbudget }
    }

    private var offBudgetAccounts: [AccountDisplay] {
        accounts.filter { !$0.account.closed && $0.account.offbudget }
    }

    private var closedAccounts: [AccountDisplay] {
        accounts.filter { $0.account.closed }
    }

    private var accountNavigationPath: Binding<[ActualAccount]> {
        Binding {
            appState.accountNavigationPath
        } set: { path in
            appState.accountNavigationPath = path
        }
    }

    @ViewBuilder
    private func accountSection(kind: AccountSectionKind, title: String, rows: [AccountDisplay]) -> some View {
        if !rows.isEmpty {
            let isExpanded = expandedSections.contains(kind)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        if isExpanded {
                            expandedSections.remove(kind)
                        } else {
                            expandedSections.insert(kind)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        Text(sectionTitle(title, count: rows.count, isExpanded: isExpanded))
                            .font(ActualistTypography.sectionTitle(for: density))
                        Spacer()
                        Text(sectionTotalText(rows, title: title))
                            .font(ActualistTypography.rowValue(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .foregroundStyle(ActualistTheme.primaryText)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            NavigationLink(value: row.account) {
                                AccountRow(
                                    row: row,
                                    isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                                    showsBottomSeparator: index < rows.count - 1
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int, isExpanded: Bool) -> String {
        isExpanded ? title : "\(title) (\(count))"
    }

    private func total(_ rows: [AccountDisplay]) -> Int {
        rows.reduce(0) { $0 + ($1.balance ?? 0) }
    }

    private func sectionTotalText(_ rows: [AccountDisplay], title: String) -> String {
        let amount = total(rows)
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return amount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            amount,
            seed: "account-section-\(title)-\(rows.map(\.id).joined(separator: "-"))",
            maximumDollars: 15_000
        )
    }

    private func load() async {
        await appState.loadBudgets()

        guard let budgetID = appState.settings.selectedBudgetID else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            guard let repository = appState.makeAccountRepository() else {
                return
            }
            await appState.refreshLocalFirstData(budgetID: budgetID)
            try await repository.refreshAccountsWithBalances(budgetID: budgetID)
        } catch {
            errorMessage = accounts.isEmpty ? error.localizedDescription : nil
        }
        isLoading = false
    }
}

private struct AccountsLoadingView: View {
    @Environment(\.actualistDensity) private var density

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading accounts")
                .font(ActualistTypography.rowTitle(for: density))
        }
        .foregroundStyle(ActualistTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct AddAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    @Bindable var viewModel: AddAccountViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Name")
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)

                        TextField("Checking", text: $viewModel.name)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.primaryText)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit {
                                Task { await submit() }
                            }
                    }
                    .padding(16)
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Type")
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)

                        Picker("Account Type", selection: $viewModel.kind) {
                            ForEach(AddAccountViewModel.AccountKind.allCases) { kind in
                                Text(kind.title)
                                    .tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(viewModel.kind.detail)
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .padding(16)
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        if viewModel.isSubmitting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Create Account")
                                .font(ActualistTypography.control(for: density))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                    .disabled(!viewModel.canSubmit)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ActualistTheme.background)
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.reset()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            if !viewModel.isSubmitting {
                viewModel.reset()
            }
        }
    }

    private func submit() async {
        guard await viewModel.submit(
            budgetID: appState.settings.selectedBudgetID,
            repository: appState.makeAccountRepository(),
            isReadOnly: !appState.capabilities.canAddAccount
        ) else {
            return
        }

        dismiss()
    }
}

private enum AccountSectionKind: Hashable {
    case budget
    case offBudget
    case closed
}

struct AccountRow: View {
    @Environment(\.actualistDensity) private var density

    let row: AccountDisplay
    let isPrivacyModeEnabled: Bool
    let showsBottomSeparator: Bool

    init(
        row: AccountDisplay,
        isPrivacyModeEnabled: Bool = false,
        showsBottomSeparator: Bool = true
    ) {
        self.row = row
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
        self.showsBottomSeparator = showsBottomSeparator
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.account.offbudget ? "tray.full.fill" : "banknote.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.accent)
                .frame(width: density.iconSize, height: density.iconSize)
                .background(ActualistTheme.elevatedSurface, in: Circle())

            Text(accountName)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)

            Spacer()

            Text(balanceText)
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle((row.balance ?? 0) >= 0 ? ActualistTheme.positive : ActualistTheme.primaryText)

            Image(systemName: "chevron.right")
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .padding(.horizontal, density.rowHorizontalPadding)
        .padding(.vertical, density.accountRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsBottomSeparator {
                Rectangle()
                    .fill(ActualistTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, density.iconSize + density.rowHorizontalPadding + 12)
            }
        }
    }

    private var accountName: String {
        guard isPrivacyModeEnabled else {
            return row.account.name
        }

        return PrivacyDisplay.name(for: .account, seed: row.account.id)
    }

    private var balanceText: String {
        guard isPrivacyModeEnabled else {
            return (row.balance ?? 0).actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            row.balance,
            seed: "account-balance-\(row.account.id)",
            maximumDollars: 15_000
        )
    }
}
