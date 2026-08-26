import SwiftUI

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.budgetCurrency) private var currency
    @State private var viewModel = AccountsViewModel()
    @State private var expandedSections: Set<AccountListLayout.Kind> = [.budget, .offBudget]

    private var sections: [AccountListLayout.Section] {
        _ = viewModel.contentRevision
        guard let budgetID = appState.settings.selectedBudgetID else {
            return []
        }
        return AccountListLayout.sections(
            displays: appState.accountRepository.accountDisplays(budgetID: budgetID),
            groups: appState.accountRepository.accountGroups(budgetID: budgetID),
            preferredIDs: appState.settings.accountOrderByBudgetID[budgetID] ?? []
        )
    }

    private var accounts: [AccountDisplay] {
        sections.flatMap(\.accounts)
    }

    private var groups: [ActualAccountGroup] {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return []
        }
        return appState.accountRepository.accountGroups(budgetID: budgetID)
    }

    private var canManageGroups: Bool {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return false
        }
        return appState.accountRepository.accountGroupManagementEnabled(budgetID: budgetID)
    }

    var body: some View {
        NavigationStack(path: accountNavigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(sections) { section in
                        accountSection(section)
                    }

                    if viewModel.isLoading && accounts.isEmpty {
                        AccountsLoadingView()
                            .padding(.vertical, 48)
                    }

                    if !viewModel.isLoading && accounts.isEmpty && viewModel.errorMessage == nil {
                        AccountsEmptyView()
                            .padding(.vertical, 48)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ActualistTheme.background)
            .navigationTitle("Accounts")
            .toolbar {
                if canManageGroups {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.presentCreateGroup()
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .font(.body.weight(.semibold))
                        .controlSize(.small)
                        .accessibilityLabel("New Group")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.isAddAccountPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .actualistToolbarGlassButton()
                    .accessibilityLabel("Add Account")
                }
            }
            .navigationDestination(for: ActualAccount.self) { account in
                AccountTransactionsView(account: account)
            }
            .task {
                await loadLocal()
                applyShortcutRoute()
            }
            .refreshable { await refresh() }
            .onAppear { applyShortcutRoute() }
            .onChange(of: appState.routeCoordinator.pendingRoute) {
                applyShortcutRoute()
            }
            .onChange(of: appState.localDataRevision) {
                Task { await loadLocal() }
                applyShortcutRoute()
            }
            .sheet(isPresented: $viewModel.isAddAccountPresented) {
                AddAccountSheet(viewModel: viewModel.addAccountViewModel)
                    .presentationDetents([.medium, .large])
                    .appSwitcherPrivacyAwareDragIndicator()
                    .appSwitcherPrivacyProtected()
            }
            .sheet(isPresented: $viewModel.isGroupEditorPresented) {
                AccountGroupEditorSheet(
                    title: viewModel.groupEditor?.title ?? "Group",
                    name: $viewModel.groupEditorName,
                    errorMessage: viewModel.errorMessage,
                    isSubmitting: viewModel.isSubmitting,
                    canSubmit: viewModel.canSubmitGroupEditor,
                    onCancel: {
                        viewModel.isGroupEditorPresented = false
                    },
                    onSubmit: {
                        await viewModel.submitGroupEditor(
                            budgetID: appState.settings.selectedBudgetID,
                            repository: appState.accountRepository
                        )
                    }
                )
                .presentationDetents([.medium])
                .appSwitcherPrivacyAwareDragIndicator()
                .appSwitcherPrivacyProtected()
            }
        }
    }

    private var deleteReviewBinding: Binding<AccountsViewModel.DeleteReview?> {
        Binding(
            get: { viewModel.deleteReview },
            set: { viewModel.deleteReview = $0 }
        )
    }

    private var deleteDialogTitle: String {
        guard let name = viewModel.deleteReview?.group.name else {
            return "Delete Group"
        }
        return "Delete \(name)?"
    }

    private var deleteDialogMessage: String {
        let names = viewModel.deleteReview?.memberNames ?? []
        if names.isEmpty {
            return "This group has no accounts."
        }
        return "\(ListFormatter.localizedString(byJoining: names)) will become ungrouped."
    }

    private func moveAccount(_ row: AccountDisplay, toGroupID groupID: String?) {
        Task {
            await viewModel.moveAccount(
                row,
                toGroupID: groupID,
                budgetID: appState.settings.selectedBudgetID,
                repository: appState.accountRepository
            )
        }
    }

    private func destinationGroups(for row: AccountDisplay) -> [ActualAccountGroup] {
        groups.filter { $0.id != row.account.accountGroupId }
    }

    private var accountNavigationPath: Binding<[ActualAccount]> {
        Binding {
            appState.accountNavigationPath
        } set: { path in
            appState.accountNavigationPath = path
        }
    }

    private func applyShortcutRoute() {
        guard let account = AppRouteApplication.account(
            from: appState.routeCoordinator.pendingRoute,
            in: accounts.map(\.account)
        ) else {
            return
        }
        appState.accountNavigationPath = [account]
        _ = appState.routeCoordinator.consume()
    }

    @ViewBuilder
    private func accountSection(_ section: AccountListLayout.Section) -> some View {
        if !section.accounts.isEmpty {
            let isExpanded = expandedSections.contains(section.kind)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        if isExpanded {
                            expandedSections.remove(section.kind)
                        } else {
                            expandedSections.insert(section.kind)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        Text(
                            sectionTitle(
                                section.kind.title,
                                count: section.accounts.count,
                                isExpanded: isExpanded
                            )
                        )
                            .font(ActualistTypography.sectionTitle(for: density))
                        Spacer()
                        Text(sectionTotalText(section.accounts, title: section.kind.title))
                            .font(ActualistTypography.rowValue(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .foregroundStyle(ActualistTheme.primaryText)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    if section.showsGroupHeaders {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(section.buckets) { bucket in
                                accountBucket(bucket)
                            }
                        }
                    } else {
                        accountCard(section.accounts)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accountBucket(_ bucket: AccountListLayout.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let group = bucket.group {
                groupHeader(group)
            }
            if bucket.accounts.isEmpty {
                if canManageGroups, let group = bucket.group {
                    Menu {
                        ForEach(accounts.filter { $0.account.accountGroupId != group.id }) { row in
                            Button(row.account.name) {
                                moveAccount(row, toGroupID: group.id)
                            }
                        }
                    } label: {
                        Text("Add Account")
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            } else {
                accountCard(bucket.accounts)
            }
        }
    }

    private func groupHeader(_ group: ActualAccountGroup) -> some View {
        HStack {
            Text(group.name)
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer()
            if canManageGroups {
                Menu {
                    groupManagementMenu(group)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Group actions")
            }
        }
        .padding(.horizontal, 4)
        .contextMenu {
            if canManageGroups {
                groupManagementMenu(group)
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: deleteReviewBinding.isPresented(matching: group.id),
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                Task {
                    await viewModel.confirmDelete(
                        budgetID: appState.settings.selectedBudgetID,
                        repository: appState.accountRepository
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelDelete()
            }
        } message: {
            Text(deleteDialogMessage)
        }
    }

    @ViewBuilder
    private func groupManagementMenu(_ group: ActualAccountGroup) -> some View {
        Button("Rename") {
            viewModel.presentRename(group)
        }
        if groups.first?.id != group.id {
            Button("Move Up") {
                Task {
                    await viewModel.moveGroupUp(
                        group,
                        groups: groups,
                        budgetID: appState.settings.selectedBudgetID,
                        repository: appState.accountRepository
                    )
                }
            }
        }
        if groups.last?.id != group.id {
            Button("Move Down") {
                Task {
                    await viewModel.moveGroupDown(
                        group,
                        groups: groups,
                        budgetID: appState.settings.selectedBudgetID,
                        repository: appState.accountRepository
                    )
                }
            }
        }
        Button("Delete", role: .destructive) {
            viewModel.presentDelete(group, displays: accounts)
        }
    }

    private func accountCard(_ rows: [AccountDisplay]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 0) {
                    NavigationLink(value: row.account) {
                        AccountRow(
                            row: row,
                            isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                            showsBottomSeparator: index < rows.count - 1
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if canManageGroups {
                            accountGroupMenu(row)
                        }
                    }

                    if canManageGroups {
                        Menu {
                            accountGroupMenu(row)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(width: 36, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Account actions")
                    }
                }
            }
        }
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func accountGroupMenu(_ row: AccountDisplay) -> some View {
        let destinations = destinationGroups(for: row)
        if !destinations.isEmpty {
            Menu("Move to Group") {
                ForEach(destinations) { group in
                    Button(group.name) {
                        moveAccount(row, toGroupID: group.id)
                    }
                }
            }
        }
        if row.account.accountGroupId != nil {
            Button("Remove from Group") {
                moveAccount(row, toGroupID: nil)
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
            return currency.formatted(amount)
        }

        return PrivacyDisplay.money(
            amount,
            seed: "account-section-\(title)-\(rows.map(\.id).joined(separator: "-"))",
            currency: currency,
            maximumDollars: 15_000
        )
    }

    private func loadLocal() async {
        await viewModel.loadLocal(
            budgetID: appState.settings.selectedBudgetID,
            hasCachedAccounts: !accounts.isEmpty,
            repository: appState.accountRepository
        )
    }

    private func refresh() async {
        await viewModel.refresh(
            budgetID: appState.settings.selectedBudgetID,
            hasCachedAccounts: !accounts.isEmpty,
            repository: appState.accountRepository,
            sync: {
                guard let budgetID = appState.settings.selectedBudgetID else {
                    return
                }
                _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
            }
        )
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

private struct AccountsEmptyView: View {
    @Environment(\.actualistDensity) private var density

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "building.columns")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ActualistTheme.accent)
            Text("No accounts yet")
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
            Text("Use the add button to create your first account.")
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
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
            repository: appState.accountRepository
        ) else {
            return
        }

        dismiss()
    }
}

struct AccountRow: View {
    @Environment(\.actualistDensity) private var density
    @Environment(\.budgetCurrency) private var currency

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

            HStack(spacing: 8) {
                if let bankSyncState = row.account.bankSyncState {
                    Circle()
                        .fill(bankSyncColor(bankSyncState))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                Text(accountName)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
            }

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
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
            return currency.formatted(row.balance ?? 0)
        }

        return PrivacyDisplay.money(
            row.balance,
            seed: "account-balance-\(row.account.id)",
            currency: currency,
            maximumDollars: 15_000
        )
    }

    private func bankSyncColor(_ state: ActualBankSyncState) -> Color {
        switch state {
        case .healthy:
            ActualistTheme.positive
        case .pending:
            ActualistTheme.warning
        case .failed:
            ActualistTheme.danger
        }
    }

    private var bankSyncAccessibilityText: String? {
        switch row.account.bankSyncState {
        case .healthy:
            "Bank sync healthy"
        case .pending:
            "Bank sync pending"
        case .failed:
            "Bank sync failed"
        case nil:
            nil
        }
    }

    private var accessibilityLabel: String {
        [accountName, balanceText, bankSyncAccessibilityText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
