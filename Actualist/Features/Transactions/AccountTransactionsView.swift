import SwiftUI

enum AccountTransactionsPresentation {
    case navigation
    case categoryInspector(onClose: @MainActor () -> Void)

    var isCategoryInspector: Bool {
        if case .categoryInspector = self { true } else { false }
    }

    @MainActor
    func closeInspector() {
        if case .categoryInspector(let onClose) = self {
            onClose()
        }
    }
}

struct AccountTransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(RootTransactionEditorPresenter.self) private var transactionPresenter
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss
    let scope: TransactionFeedScope
    let onChanged: @MainActor () -> Void
    let categoryCarryoverIsEnabled: Bool?
    let categoryNotePresentation: ActualNotePresentation?
    let categoryCarryoverIsUpdating: Bool
    let canEditCategoryCarryover: Bool
    let categoryCarryoverErrorMessage: String?
    let onCategoryCarryoverChanged: @MainActor (Bool) -> Void
    let templateDoor: BudgetTemplateDoorRow?
    let onOpenTemplates: () -> Void
    let presentation: AccountTransactionsPresentation

    @FocusState private var isSearchFieldFocused: Bool
    @State private var isSearchFieldVisible = false
    @State private var viewModel: AccountTransactionsViewModel
    @State private var reconciliationCoordinator = AccountReconciliationCoordinator()

    init(account: ActualAccount) {
        self.scope = .account(account)
        self.onChanged = {}
        self.categoryCarryoverIsEnabled = nil
        self.categoryNotePresentation = nil
        self.categoryCarryoverIsUpdating = false
        self.canEditCategoryCarryover = false
        self.categoryCarryoverErrorMessage = nil
        self.onCategoryCarryoverChanged = { _ in }
        self.templateDoor = nil
        self.onOpenTemplates = {}
        self.presentation = .navigation
        _viewModel = State(initialValue: AccountTransactionsViewModel(scope: .account(account)))
    }

    init(
        scope: TransactionFeedScope,
        onChanged: @escaping @MainActor () -> Void = {},
        categoryCarryoverIsEnabled: Bool? = nil,
        categoryNotePresentation: ActualNotePresentation? = nil,
        categoryCarryoverIsUpdating: Bool = false,
        canEditCategoryCarryover: Bool = false,
        categoryCarryoverErrorMessage: String? = nil,
        onCategoryCarryoverChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        templateDoor: BudgetTemplateDoorRow? = nil,
        onOpenTemplates: @escaping () -> Void = {},
        presentation: AccountTransactionsPresentation = .navigation
    ) {
        self.scope = scope
        self.onChanged = onChanged
        self.categoryCarryoverIsEnabled = categoryCarryoverIsEnabled
        self.categoryNotePresentation = categoryNotePresentation
        self.categoryCarryoverIsUpdating = categoryCarryoverIsUpdating
        self.canEditCategoryCarryover = canEditCategoryCarryover
        self.categoryCarryoverErrorMessage = categoryCarryoverErrorMessage
        self.onCategoryCarryoverChanged = onCategoryCarryoverChanged
        self.templateDoor = templateDoor
        self.onOpenTemplates = onOpenTemplates
        self.presentation = presentation
        _viewModel = State(initialValue: AccountTransactionsViewModel(scope: scope))
    }

    private var budgetID: String? {
        appState.settings.selectedBudgetID
    }

    private var budgetCurrency: BudgetCurrency {
        guard let budgetID else { return .usd }
        return appState.localFirstStore.budgetCurrency(budgetID: budgetID)
    }

    private var transactionRepository: any TransactionRepositoryProtocol {
        appState.transactionRepository
    }

    private var accountRepository: any AccountRepositoryProtocol {
        appState.accountRepository
    }

    private var reconciliationIdentity: AccountReconciliationIdentity? {
        guard let budgetID, let account = scope.account else { return nil }
        return AccountReconciliationIdentity(budgetID: budgetID, accountID: account.id)
    }

    private var pendingNewTransactionIDs: Set<String> {
        guard let budgetID else {
            return []
        }
        switch scope {
        case .account(let account):
            return appState.pendingNewTransactionIDs(budgetID: budgetID, accountID: account.id)
        case .spending, .category:
            return appState.pendingNewTransactionIDs(budgetID: budgetID)
        }
    }

    var body: some View {
        let displayState = viewModel.displayState(
            budgetID: budgetID,
            repository: transactionRepository,
            pendingNewTransactionIDs: pendingNewTransactionIDs,
            privacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
            currency: budgetCurrency
        )

        return List {
            if isSearchFieldVisible {
                Section {
                    searchBar
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if scope.showsSummaryHeader {
                Section {
                    header(displayState)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            if let presentation = reconciliationCoordinator.panelPresentation(
                privacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled
            ) {
                Section {
                    reconciliationPanel(presentation)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            if scope.categoryDetails == nil {
                Section {
                    TransactionStatusFilterStrip(selection: viewModel.statusFilter) { filter in
                        Task {
                            await viewModel.selectFilter(filter, budgetID: budgetID,
                                                         repository: transactionRepository)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }

            transactionList(displayState)

            if viewModel.isSearchActive {
                searchFooter(displayState)
            } else {
                olderTransactionsFooter(displayState)
            }

            if viewModel.isLoading {
                ProgressView(viewModel.statusFilter.loadingMessage)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let errorMessage = viewModel.loadErrorMessage ?? viewModel.errorMessage {
                Text(errorMessage)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .padding(.horizontal, 16)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                if displayState.transactionCount == 0 {
                    Button("Retry") {
                        Task { await viewModel.loadLocal(budgetID: budgetID, repository: transactionRepository) }
                    }
                    .font(ActualistTypography.control(for: density))
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .modifier(TransactionNavigationTitleModifier(
            title: displayState.title,
            isVisible: !presentation.isCategoryInspector
        ))
        .safeAreaBar(edge: .top, spacing: 0) {
            if presentation.isCategoryInspector {
                inspectorHeader(displayState)
            }
        }
        .toolbar {
            if !presentation.isCategoryInspector {
                if scope.categoryDetails != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close Category Details")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if scope.account != nil {
                        Menu {
                            Button {
                                startReconciliation()
                            } label: {
                                Label("Reconcile", systemImage: "checkmark.seal")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .actualistToolbarGlassButton()
                        .accessibilityLabel("Account Actions")
                    }

                    Button {
                        showSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .actualistToolbarGlassButton()
                    .accessibilityLabel("Search Transactions")

                    Button {
                        viewModel.showCreateEditor(using: appState, presenter: transactionPresenter)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .actualistToolbarGlassButton()
                    .accessibilityLabel("Add Transaction")
                }
            }
        }
        .task {
            await viewModel.loadLocal(budgetID: budgetID, repository: transactionRepository)
        }
        .refreshable {
            await viewModel.refresh(
                budgetID: budgetID,
                repository: transactionRepository,
                sync: {
                    guard let budgetID else { return }
                    _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
                },
                onChanged: onChanged
            )
        }
        .onChange(of: appState.localDataRevision) {
            Task {
                await viewModel.localDataDidChange(budgetID: budgetID, repository: transactionRepository)
                if let reconciliationIdentity {
                    reconciliationCoordinator.refreshIfActive(
                        identity: reconciliationIdentity,
                        repository: accountRepository
                    )
                }
            }
        }
        .onChange(of: budgetID) { _, _ in
            Task { await viewModel.budgetDidChange(to: budgetID, repository: transactionRepository) }
        }
        .onChange(of: transactionPresenter.presentation == nil) { _, editorDismissed in
            viewModel.editorPresentationChanged(
                editorDismissed: editorDismissed,
                budgetID: budgetID,
                repository: transactionRepository
            )
        }
        .onChange(of: reconciliationIdentity) {
            reconciliationCoordinator.reconcileContext(reconciliationIdentity)
        }
        .onDisappear {
            viewModel.feedDidDisappear(editorIsPresented: transactionPresenter.presentation != nil)
            reconciliationCoordinator.cancel()
            viewModel.clearPendingNewTransactions(budgetID: budgetID) { budgetID, accountID in
                if let accountID {
                    appState.clearPendingNewTransactionIDs(budgetID: budgetID, accountID: accountID)
                } else {
                    appState.clearPendingNewTransactionIDs(budgetID: budgetID)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: viewModel.deleteIntentFeedback)
        .sensoryFeedback(.success, trigger: viewModel.deleteSuccessFeedback)
        .sheet(isPresented: reconciliationSheetBinding) {
            AccountReconciliationTargetSheet(
                coordinator: reconciliationCoordinator,
                privacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                onRetry: retryReconciliationStart
            )
            .appSwitcherPrivacyProtected(using: appState)
        }
    }

    private var deletePresentationBinding: Binding<TransactionDeletePresentation?> {
        Binding(
            get: { viewModel.deletePresentation },
            set: { viewModel.deletePresentation = $0 }
        )
    }

    private var reconciliationSheetBinding: Binding<Bool> {
        Binding(
            get: { reconciliationCoordinator.presentsTargetSheet },
            set: { isPresented in
                if !isPresented {
                    reconciliationCoordinator.targetSheetDismissed()
                }
            }
        )
    }

    private func inspectorHeader(_ displayState: AccountTransactionsDisplayState) -> some View {
        HStack(spacing: 12) {
            Button {
                presentation.closeInspector()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close Category Details")

            Text(displayState.title)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                showSearch()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search Transactions")

            Button {
                viewModel.showCreateEditor(using: appState, presenter: transactionPresenter)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Transaction")
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ActualistTheme.background)
        .overlay(alignment: .bottom) {
            Divider().overlay(ActualistTheme.separator)
        }
    }
    private func header(_ displayState: AccountTransactionsDisplayState) -> some View {
        AccountTransactionsSummaryView(
            scope: scope,
            displayState: displayState,
            categoryCarryoverIsEnabled: categoryCarryoverIsEnabled,
            categoryNotePresentation: categoryNotePresentation,
            categoryCarryoverIsUpdating: categoryCarryoverIsUpdating,
            canEditCategoryCarryover: canEditCategoryCarryover,
            categoryCarryoverErrorMessage: categoryCarryoverErrorMessage,
            onCategoryCarryoverChanged: onCategoryCarryoverChanged,
            templateDoor: templateDoor,
            onOpenTemplates: onOpenTemplates
        )
    }

    private func reconciliationPanel(
        _ presentation: AccountReconciliationPanelPresentation
    ) -> some View {
        AccountReconciliationPanel(
            presentation: presentation,
            onCreateAdjustment: {
                reconciliationCoordinator.createAdjustment(
                    repository: accountRepository,
                    didMutate: reconciliationDidMutate
                )
            },
            onLockTransactions: {
                reconciliationCoordinator.lockTransactions(
                    repository: accountRepository,
                    didMutate: reconciliationDidMutate
                )
            },
            onExit: {
                reconciliationCoordinator.exit(
                    repository: accountRepository,
                    didMutate: reconciliationDidMutate
                )
            },
            onRetryRefresh: {
                guard let reconciliationIdentity else { return }
                reconciliationCoordinator.refreshIfActive(
                    identity: reconciliationIdentity,
                    repository: accountRepository
                )
            }
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .accessibilityHidden(true)

            TextField(
                "Search Transactions",
                text: Binding(
                    get: { viewModel.searchText },
                    set: { value in
                        viewModel.searchTextDidChange(
                            value, budgetID: budgetID, repository: transactionRepository
                        )
                    }
                )
            )
                .focused($isSearchFieldFocused)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .tint(ActualistTheme.accent)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                if viewModel.isSearchActive {
                    viewModel.clearSearch(budgetID: budgetID, repository: transactionRepository)
                    isSearchFieldFocused = true
                } else {
                    hideSearch()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isSearchActive ? "Clear Search" : "Close Search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ActualistTheme.control, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func transactionList(_ displayState: AccountTransactionsDisplayState) -> some View {
        ForEach(displayState.groups) { group in
            Text(group.title)
                .font(ActualistTypography.sectionTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .textCase(nil)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .padding(.horizontal, density.rowHorizontalPadding)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                transactionButton(
                    for: row,
                    showsBottomSeparator: index < group.rows.count - 1
                )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(ActualistTheme.surface)
            }
        }
    }

    @ViewBuilder
    private func searchFooter(_ displayState: AccountTransactionsDisplayState) -> some View {
        Group {
            if viewModel.isSearchLoading(budgetID: budgetID) {
                ProgressView(viewModel.statusFilter.searchingMessage)
                    .font(ActualistTypography.rowBadge(for: density))
            } else if let searchErrorMessage = viewModel.searchErrorMessage {
                VStack(spacing: 8) {
                    Text(searchErrorMessage)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.danger)
                    Button("Retry Search") {
                        viewModel.retrySearch(budgetID: budgetID, repository: transactionRepository)
                    }
                    .font(ActualistTypography.control(for: density))
                    if displayState.transactionCount > 0, !displayState.reachedEnd {
                        Button {
                            Task { await viewModel.loadOlder(budgetID: budgetID, repository: transactionRepository) }
                        } label: {
                            if viewModel.isLoadingOlder {
                                ProgressView("Loading older transactions")
                            } else {
                                Label("Load older transactions", systemImage: "clock.arrow.circlepath")
                            }
                        }
                        .font(ActualistTypography.control(for: density))
                        .buttonStyle(.plain)
                    }
                }
            } else if displayState.transactionCount == 0 {
                Text(viewModel.statusFilter == .all
                     ? "No matching transactions"
                     : "No matching \(viewModel.statusFilter.title.lowercased()) transactions")
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
            } else if !displayState.reachedEnd {
                Button {
                    Task { await viewModel.loadOlder(budgetID: budgetID, repository: transactionRepository) }
                } label: {
                    if viewModel.isLoadingOlder {
                        ProgressView("Loading older transactions")
                    } else {
                        Label("Load older transactions", systemImage: "clock.arrow.circlepath")
                    }
                }
                .font(ActualistTypography.control(for: density))
                .buttonStyle(.plain)
            } else if displayState.transactionCount > 0 {
                Text("Beginning of history")
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func olderTransactionsFooter(_ displayState: AccountTransactionsDisplayState) -> some View {
        if displayState.hasLoadedSnapshot {
            Group {
                if displayState.transactionCount == 0 {
                    Text(viewModel.statusFilter.emptyMessage)
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                } else if displayState.reachedEnd {
                    Text(viewModel.statusFilter == .all
                         ? "Beginning of history"
                         : "End of \(viewModel.statusFilter.title.lowercased()) transactions")
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                } else if viewModel.isLoadingOlder {
                    ProgressView("Loading older transactions")
                        .font(ActualistTypography.rowBadge(for: density))
                } else {
                    Button {
                        Task {
                            await viewModel.loadOlder(
                                budgetID: budgetID,
                                repository: transactionRepository
                            )
                        }
                    } label: {
                        Label("Load older transactions", systemImage: "clock.arrow.circlepath")
                            .font(ActualistTypography.control(for: density))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .onAppear {
                Task {
                    await viewModel.loadOlder(
                        budgetID: budgetID,
                        repository: transactionRepository
                    )
                }
            }
        }
    }

    private func transactionButton(
        for row: AccountTransactionRowPresentation,
        showsBottomSeparator: Bool
    ) -> some View {
        Button {
            viewModel.showEditor(
                for: row.transaction,
                using: appState,
                presenter: transactionPresenter
            )
        } label: {
            TransactionRow(
                transaction: row.transaction,
                semantics: row.semantics,
                accountName: row.accountName,
                isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                highlightsIncomeAmounts: appState.settings.greenIncomeTransactionAmountsEnabled,
                isNew: row.isNew,
                showsBottomSeparator: showsBottomSeparator
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.deletingTransactionID == row.transaction.rowID)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task {
                    await viewModel.requestDelete(
                        row.transaction,
                        budgetID: budgetID,
                        repository: transactionRepository
                    )
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(ActualistTheme.danger)
            .disabled(row.transaction.id == nil || viewModel.deletingTransactionID != nil)
        }
        .confirmationDialog(
            viewModel.deletePresentation?.confirmationTitle ?? "Delete Transaction?",
            isPresented: deletePresentationBinding.isPresented(matching: row.id),
            titleVisibility: .visible
        ) {
            Button(
                viewModel.deletePresentation?.actionTitle ?? "Delete Transaction",
                role: .destructive
            ) {
                let authorization = viewModel.deletePresentation?.reconciliationAuthorization
                Task {
                    await viewModel.delete(
                        row.transaction,
                        budgetID: budgetID,
                        repository: transactionRepository,
                        reconciliationAuthorization: authorization,
                        onChanged: onChanged
                    )
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                viewModel.deletePresentation?.message
                    ?? "Delete \(row.payeeName)? Actualist will confirm the server update before refreshing \(scope.refreshTargetDescription)."
            )
        }
    }

    private func showSearch() {
        withAnimation(.snappy(duration: 0.22)) {
            isSearchFieldVisible = true
        }

        Task { @MainActor in
            await Task.yield()
            guard isSearchFieldVisible else {
                return
            }
            isSearchFieldFocused = true
        }
    }

    private func hideSearch() {
        viewModel.clearSearch(budgetID: budgetID, repository: transactionRepository)
        isSearchFieldFocused = false

        withAnimation(.snappy(duration: 0.2)) {
            isSearchFieldVisible = false
        }
    }

    private func startReconciliation() {
        guard let reconciliationIdentity else { return }
        reconciliationCoordinator.start(
            identity: reconciliationIdentity,
            currency: budgetCurrency,
            repository: accountRepository
        )
    }

    private func retryReconciliationStart() {
        reconciliationCoordinator.cancel()
        startReconciliation()
    }

    private func reconciliationDidMutate() {
        appState.recordLocalDataMutation()
        onChanged()
    }
}

private struct TransactionNavigationTitleModifier: ViewModifier {
    let title: String
    let isVisible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVisible {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}
