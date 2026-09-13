import SwiftUI

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: BudgetViewModel
    @Environment(RootTransactionEditorPresenter.self) private var transactionPresenter
    @State private var isHistoryPresented = false
    @State private var isMonthPickerPresented = false
    @State private var isUncategorizedTransactionsPresented = false
    @State private var uncategorizedRouteMonth: String?
    @State private var categoryDetailsPresentation: CategoryMonthDetails?
    @State private var isOverspentCategoriesPresented = false
    @State private var assignmentInsetBottomY: CGFloat = 0
    @State private var compactScrollPosition = ScrollPosition(y: 0)
    @State private var compactScrollSample = ScrollDirectedExpansionSample(offset: 0, maxOffset: 0)
    @State private var assignmentScrollBottomPadding = BudgetLayout.sectionSpacing
    @State private var pendingAssignmentOpening: BudgetAssignmentOpeningRequest?
    @State private var pendingTemplateConfirmation: BudgetTemplateConfirmation?
    @State private var templateEditorTarget: BudgetTemplateEditorTarget?
    @State private var noteTarget: ActualNoteTarget?
    @State private var visibilityWorkflow = BudgetCategoryVisibilityWorkflow()
    @State private var addTransactionExpansion = ScrollDirectedExpansion()
    let loadsOnAppear: Bool

    init(viewModel: BudgetViewModel, loadsOnAppear: Bool = true) {
        _viewModel = State(initialValue: viewModel)
        self.loadsOnAppear = loadsOnAppear
    }

    init(initialMonth: LoadedBudgetMonth? = nil, initialBudgetID: String? = nil) {
        _viewModel = State(
            initialValue: BudgetViewModel(
                initialMonth: initialMonth,
                initialBudgetID: initialBudgetID
            )
        )
        self.loadsOnAppear = true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                    VStack(spacing: BudgetLayout.sectionSpacing) {
                        if viewModel.budgetMonth != nil {
                            operationErrorBanner
                            compactContent(viewModel)
                        } else if viewModel.isLoading {
                            loadingState
                        } else {
                            emptyState
                        }
                    }
                    .padding(.horizontal, BudgetLayout.screenHorizontalPadding)
                    .padding(.top, 4)
                    .padding(.bottom, assignmentScrollBottomPadding)
                }
                .scrollPosition($compactScrollPosition)
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("budget-compact-scroll")
                .background(ActualistTheme.background)
                .onScrollGeometryChange(for: ScrollDirectedExpansionSample.self) { geometry in
                    ScrollDirectedExpansionSample(
                        offset: geometry.visibleRect.minY,
                        maxOffset: max(0, geometry.contentSize.height - geometry.visibleRect.height),
                        topInset: geometry.contentInsets.top
                    )
                } action: { previous, current in
                    compactScrollSample = current
                    updateAddTransactionExpansion(previous: previous, current: current)
                    beginPreparedAssignmentOpeningIfNeeded()
                }
                .modifier(BudgetMonthSwipeModifier(
                    model: viewModel,
                    presentationBlocked: monthSwipePresentationBlocked,
                    verticalOffset: compactScrollSample.offset
                ))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Group {
                        if viewModel.isAssignmentKeypadPresented {
                            BudgetAssignmentKeypad(
                                canSubmit: viewModel.canSubmitAssignment,
                                showsApplyTemplate: viewModel.activeCategoryHasTemplate,
                                showsMoveMoney: !viewModel.isTrackingBudget,
                                canApplyTemplate: viewModel.canApplyCategoryTemplate,
                                isSubmitting: viewModel.isSubmittingAssignment,
                                errorMessage: viewModel.activeAssignmentErrorMessage,
                                appendDigit: { viewModel.appendAssignmentDigit($0) },
                                setMode: { viewModel.setAssignmentInputMode($0) },
                                applyTemplate: {
                                    pendingTemplateConfirmation = .category
                                },
                                moveMoney: {
                                    withAnimation(BudgetLayout.assignmentKeypadAnimation) {
                                        viewModel.beginMoveMoney()
                                    }
                                },
                                details: {
                                    guard let details = viewModel.activeCategoryMonthDetails else {
                                        return
                                    }
                                    categoryDetailsPresentation = details
                                    dismissAssignmentKeypad {
                                        viewModel.cancelAssignmentEditing()
                                    }
                                },
                                deleteDigit: { viewModel.deleteAssignmentDigit() },
                                clearOrCancel: {
                                    if viewModel.assignmentDraft?.inputDigits.isEmpty == true {
                                        dismissAssignmentKeypad {
                                            viewModel.clearOrCancelAssignmentInput()
                                        }
                                    } else {
                                        viewModel.clearOrCancelAssignmentInput()
                                    }
                                },
                                cancel: {
                                    dismissAssignmentKeypad {
                                        viewModel.cancelAssignmentEditing()
                                    }
                                },
                                submit: {
                                    Task { await viewModel.submitAssignment(using: appState) }
                                }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            HStack {
                                Spacer(minLength: 0)
                                BudgetAddTransactionButton(isExpanded: addTransactionExpansion.isExpanded) {
                                    transactionPresenter.present(using: appState)
                                }
                            }
                            .padding(.horizontal, BudgetLayout.screenHorizontalPadding)
                            .padding(.bottom, BudgetLayout.addTransactionFloatingPadding)
                            .frame(maxWidth: .infinity)
                            .background {
                                if dynamicTypeSize.isAccessibilitySize {
                                    ActualistTheme.background
                                }
                            }
                        }
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear {
                                    assignmentInsetBottomY = geometry.frame(in: .global).maxY
                                }
                                .onChange(of: geometry.frame(in: .global).maxY) { _, bottom in
                                    assignmentInsetBottomY = bottom
                                }
                        }
                    }
                }
                .animation(BudgetLayout.assignmentKeypadAnimation, value: viewModel.isAssignmentKeypadPresented)
                .navigationTitle(viewModel.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            appState.routeCoordinator.presentSettings(path: [])
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .actualistToolbarGlassButton()
                        .accessibilityLabel("Settings")
                    }

                    ToolbarItem(placement: .principal) {
                        Button {
                            isMonthPickerPresented.toggle()
                        } label: {
                            HStack(spacing: 7) {
                                ConnectionStatusDot(status: appState.connectionStatus, isDemo: appState.isDemoMode)
                                Text(viewModel.navigationTitle)
                                    .font(.headline.weight(.bold))
                                if viewModel.budgetMonth?.hasUserNote == true {
                                    Image(systemName: "note.text")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(ActualistTheme.secondaryText)
                                        .accessibilityHidden(true)
                                }
                                Image(systemName: "chevron.down")
                                    .font(.subheadline.weight(.bold))
                                    .rotationEffect(.degrees(isMonthPickerPresented ? 180 : 0))
                            }
                            .foregroundStyle(ActualistTheme.primaryText)
                        }
                        .popover(isPresented: $isMonthPickerPresented, arrowEdge: .top) {
                            BudgetMonthPicker(
                                availableMonths: viewModel.availableMonths,
                                selectedMonth: viewModel.selectedMonth,
                                allowsUnlistedMonths: true
                            ) { month in
                                isMonthPickerPresented = false
                                Task { await viewModel.selectMonth(month, using: appState) }
                            }
                            .presentationCompactAdaptation(.popover)
                            .appSwitcherPrivacyProtected(using: appState)
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                isHistoryPresented = true
                            } label: {
                                Label("History", systemImage: "clock.arrow.circlepath")
                            }

                            Divider()

                            Button {
                                presentMonthNote()
                            } label: {
                                Label("Notes", systemImage: "note.text")
                            }
                            .disabled(viewModel.selectedMonth == nil)

                            Divider()

                            Toggle(
                                "Show Hidden Categories",
                                systemImage: "eye",
                                isOn: showHiddenCategoriesBinding
                            )

                            if viewModel.hasMonthTemplateActions {
                                Divider()

                                Button {
                                    pendingTemplateConfirmation = .monthFillEmpty
                                } label: {
                                    Label("Apply Template", systemImage: "sparkles")
                                }
                                .disabled(viewModel.isApplyingMonthTemplate)

                                Button {
                                    pendingTemplateConfirmation = .monthOverwrite
                                } label: {
                                    Label("Apply Template Overwrite", systemImage: "sparkles.square.filled.on.square")
                                }
                                .disabled(viewModel.isApplyingMonthTemplate)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .font(.body.weight(.semibold))
                        .controlSize(.small)
                        .accessibilityLabel("Budget Actions")
                    }
                }
                .task {
                    if loadsOnAppear { await viewModel.load(using: appState) }
                }
                .refreshable { await viewModel.refresh(using: appState) }
                .onChange(of: viewModel.assignmentWorkflow.completionRevision) {
                    Task { await viewModel.refreshSelectedMonth(using: appState) }
                }
                .onChange(of: appState.localDataRevision) {
                    Task { await viewModel.refreshSelectedMonth(using: appState) }
                }
                .onChange(of: appState.selectedTab) { _, tab in
                    // Other tabs can invalidate this month while Budget is hidden.
                    if tab == .budget {
                        Task { await viewModel.refreshSelectedMonth(using: appState) }
                    }
                }
                .onChange(of: appState.settings.includeCarryoverCategoriesInOverspentAlerts) { _, isEnabled in
                    viewModel.includeCarryoverCategoriesInOverspentAlerts = isEnabled
                }
                .onAppear { applyShortcutRoute() }
                .onChange(of: appState.routeCoordinator.pendingRoute) {
                    applyShortcutRoute()
                }
                .onChange(of: viewModel.isLoading) {
                    if !viewModel.isLoading {
                        applyShortcutRoute()
                    }
                }
                .onChange(of: viewModel.selectedMonth) {
                    visibilityWorkflow.cancel()
                    noteTarget = nil
                    applyShortcutRoute()
                }
                .onChange(of: appState.settings.selectedBudgetID) {
                    noteTarget = nil
                }
                .sheet(isPresented: $isHistoryPresented) {
                    HistoryView()
                        .appSwitcherPrivacyProtected(using: appState)
                }
                .fullScreenCover(
                    isPresented: Binding(
                        get: { appState.routeCoordinator.isSettingsPresented },
                        set: { appState.routeCoordinator.setSettingsPresented($0) }
                    ),
                    onDismiss: appState.routeCoordinator.settingsDidDismiss
                ) {
                    SettingsView(showsDismissButton: true)
                        .appSwitcherPrivacyProtected(using: appState)
                }
                .sheet(isPresented: $isUncategorizedTransactionsPresented) {
                    UncategorizedTransactionsView(
                        month: uncategorizedRouteMonth ?? viewModel.selectedMonth ?? viewModel.preferredMonth,
                        cachedSnapshot: cachedUncategorizedTransactions,
                        onChanged: {
                            Task { await viewModel.refreshSelectedMonth(using: appState) }
                        },
                        onResolvedAll: {
                            isUncategorizedTransactionsPresented = false
                        }
                    )
                    .appSwitcherPrivacyProtected(using: appState)
                }
                .sheet(item: $categoryDetailsPresentation, onDismiss: {
                    Task { await viewModel.refreshSelectedMonth(using: appState) }
                }) { details in
                    CategoryMonthDetailsView(details: details)
                        .appSwitcherPrivacyProtected(using: appState)
                }
                .sheet(item: $templateEditorTarget, onDismiss: {
                    Task { await viewModel.refreshSelectedMonth(using: appState) }
                }) { target in
                    BudgetTemplateEditorView(target: target) {
                        Task { await viewModel.refreshSelectedMonth(using: appState) }
                    }
                    .appSwitcherPrivacyProtected(using: appState)
                }
                .sheet(item: $noteTarget) { target in
                    if let budgetID = appState.settings.selectedBudgetID {
                        EntityNotesView(
                            target: target,
                            budgetID: budgetID,
                            isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                            repository: appState.localFirstStore,
                            onSaved: {
                                Task { await viewModel.refreshSelectedMonth(using: appState) }
                            }
                        )
                        .appSwitcherPrivacyProtected(using: appState)
                    }
                }
                .sheet(isPresented: $isOverspentCategoriesPresented) {
                    BudgetOverspentCategoriesView(
                        viewModel: viewModel,
                        isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled
                    )
                    .appSwitcherPrivacyProtected(using: appState)
                }
                .sheet(isPresented: moveMoneyPresentationBinding) {
                    BudgetMoveMoneyView(
                        viewModel: viewModel,
                        onSaved: {}
                    )
                        .appSwitcherPrivacyProtected(using: appState)
                }
                .modifier(
                    BudgetTemplateConfirmationModifier(
                        confirmation: $pendingTemplateConfirmation,
                        categoryID: viewModel.activeAssignmentCategoryID,
                        month: viewModel.selectedMonth,
                        modeIdentity: viewModel.modeIdentity,
                        apply: applyTemplate
                    )
                )
                .onChange(of: viewModel.activeAssignmentCategoryID) { _, categoryID in
                    guard categoryID == nil else {
                        return
                    }
                    pendingAssignmentOpening = nil
                    if assignmentScrollBottomPadding != BudgetLayout.sectionSpacing {
                        withAnimation(BudgetLayout.assignmentKeypadAnimation) {
                            assignmentScrollBottomPadding = BudgetLayout.sectionSpacing
                        }
                    }
                }
        }
    }

    private var monthSwipePresentationBlocked: Bool {
        isHistoryPresented || isMonthPickerPresented || isUncategorizedTransactionsPresented
            || categoryDetailsPresentation != nil || isOverspentCategoriesPresented
            || pendingTemplateConfirmation != nil || templateEditorTarget != nil || noteTarget != nil
            || transactionPresenter.presentation != nil || appState.routeCoordinator.isSettingsPresented
            || visibilityWorkflow.isSubmitting
    }

    private func applyTemplate(_ confirmation: BudgetTemplateConfirmation, reviewedMode: BudgetModeIdentity?) {
        switch confirmation {
        case .monthFillEmpty:
            Task { await viewModel.applyMonthTemplate(.fillEmpty, expectedMode: reviewedMode, using: appState) }
        case .monthOverwrite:
            Task { await viewModel.applyMonthTemplate(.overwrite, expectedMode: reviewedMode, using: appState) }
        case .category:
            Task { await viewModel.applyCategoryTemplate(expectedMode: reviewedMode, using: appState) }
        }
    }

    private func toggleCategoryHidden(
        _ category: BudgetMonthCategory,
        in group: BudgetMonthCategoryGroup
    ) {
        Task {
            guard await visibilityWorkflow.setCategoryHidden(
                !BudgetCategoryVisibility.isHidden(category.hidden),
                categoryID: category.id,
                groupHidden: BudgetCategoryVisibility.isHidden(group.hidden),
                selectedMonth: viewModel.selectedMonth,
                budgetID: appState.settings.selectedBudgetID,
                repository: appState.budgetRepository
            ) != nil else {
                return
            }
            await viewModel.refreshSelectedMonth(using: appState)
        }
    }

    private func toggleGroupHidden(_ group: BudgetMonthCategoryGroup) {
        Task {
            guard await visibilityWorkflow.setGroupHidden(
                !BudgetCategoryVisibility.isHidden(group.hidden),
                group: group,
                selectedMonth: viewModel.selectedMonth,
                budgetID: appState.settings.selectedBudgetID,
                repository: appState.budgetRepository
            ) != nil else {
                return
            }
            await viewModel.refreshSelectedMonth(using: appState)
        }
    }

    private var moveMoneyPresentationBinding: Binding<Bool> {
        Binding {
            viewModel.isMoveMoneyPresented
        } set: { isPresented in
            if !isPresented {
                viewModel.cancelMoveMoney()
            }
        }
    }

    @ViewBuilder
    private var operationErrorBanner: some View {
        if let message = viewModel.errorMessage ?? visibilityWorkflow.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body.weight(.bold))

                Text(message)
                    .font(ActualistTypography.body(for: density))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .foregroundStyle(ActualistTheme.danger)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ActualistTheme.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var showHiddenCategoriesBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.showHiddenCategories },
            set: { appState.updateShowHiddenCategories($0) }
        )
    }

    private func applyShortcutRoute() {
        if case .settings = appState.routeCoordinator.pendingRoute {
            appState.routeCoordinator.presentSettings()
            _ = appState.routeCoordinator.consume()
            return
        }
        if case .history = appState.routeCoordinator.pendingRoute {
            isHistoryPresented = true
            _ = appState.routeCoordinator.consume()
            return
        }
        if let month = AppRouteApplication.uncategorizedMonth(from: appState.routeCoordinator.pendingRoute) {
            uncategorizedRouteMonth = month.isEmpty ? nil : month
            isUncategorizedTransactionsPresented = true
            _ = appState.routeCoordinator.consume()
            return
        }
        let categories = viewModel.budgetMonth?.categoryGroups.flatMap(\.categories) ?? []
        guard let applied = AppRouteApplication.category(
            from: appState.routeCoordinator.pendingRoute,
            in: categories
        ) else {
            return
        }
        _ = appState.routeCoordinator.consume()
        if viewModel.selectedMonth != applied.month {
            Task { await viewModel.selectMonth(applied.month, using: appState) }
        }
        categoryDetailsPresentation = CategoryMonthDetails(
            category: applied.category,
            month: applied.month,
            modeIdentity: viewModel.modeIdentity
        )
    }

    private func realCategory(id: String) -> BudgetMonthCategory? {
        viewModel.budgetMonth?.categoryGroups
            .flatMap(\.categories)
            .first { $0.id == id }
    }

    private func open(_ alert: BudgetAlert) {
        guard alert.isActionable else {
            return
        }

        switch alert.kind {
        case .uncategorizedTransactions:
            isUncategorizedTransactionsPresented = true
        case .overspending:
            isOverspentCategoriesPresented = true
        case .toBudget:
            break
        }
    }

    private var cachedUncategorizedTransactions: LoadedUncategorizedTransactions? {
        guard let budgetID = appState.settings.selectedBudgetID else {
            return nil
        }
        let repository = appState.transactionRepository
        return repository.cachedUncategorizedTransactions(
            budgetID: budgetID,
            month: uncategorizedRouteMonth ?? viewModel.selectedMonth ?? viewModel.preferredMonth
        )
    }

    private func compactContent(_ model: BudgetViewModel) -> some View {
        BudgetCompactMonthContent(viewModel: model, canChangeVisibility: !visibilityWorkflow.isSubmitting) { action in
            switch action {
            case .edit(let id, let frame):
                guard let category = realCategory(id: id) else { return }
                let target = BudgetAssignmentScrollGeometry.openingTarget(
                    currentOffset: compactScrollSample.offset,
                    topInset: compactScrollSample.topInset,
                    rowFrame: frame,
                    insetBottomY: assignmentInsetBottomY,
                    keypadHeight: BudgetKeypadLayout.initialHeight,
                    visibilityMargin: BudgetLayout.assignmentScrollVisibilityMargin
                )
                beginAssignmentEditing(category, scrollTarget: target)
            case .toggle(let group):
                withAnimation(.smooth(duration: 0.2)) { viewModel.toggle(group) }
            case .alert(let alert): open(alert)
            case .categoryNote(let category):
                noteTarget = ActualNoteTarget.category(id: category.id, title: category.name.actualistCategoryNameParts.name)
            case .groupNote(let group):
                noteTarget = ActualNoteTarget.categoryGroup(id: group.id, title: group.name)
            case .templates(let category): presentTemplates(for: category)
            case .categoryVisibility(let category, let group): toggleCategoryHidden(category, in: group)
            case .groupVisibility(let group): toggleGroupHidden(group)
            }
        }
    }

    private func presentMonthNote() {
        guard let month = viewModel.selectedMonth else {
            return
        }
        noteTarget = ActualNoteTarget.budgetMonth(
            month: month,
            title: viewModel.navigationTitle
        )
    }

    private func presentTemplates(for category: BudgetMonthCategory) {
        guard canManageTemplates(category), let month = viewModel.selectedMonth else {
            return
        }
        templateEditorTarget = BudgetTemplateEditorTarget(
            categoryID: category.id,
            categoryName: category.name.actualistCategoryNameParts.name,
            month: month
        )
    }

    private func canManageTemplates(_ category: BudgetMonthCategory) -> Bool {
        if category.isIncome {
            return viewModel.isTrackingBudget
        }
        return true
    }

    private func updateAddTransactionExpansion(
        previous: ScrollDirectedExpansionSample,
        current: ScrollDirectedExpansionSample
    ) {
        var next = addTransactionExpansion
        next.update(
            previousOffset: previous.offset,
            offset: current.offset,
            maxOffset: current.maxOffset
        )
        guard next != addTransactionExpansion else {
            return
        }
        withAnimation(BudgetLayout.addTransactionExpansionAnimation) {
            addTransactionExpansion = next
        }
    }

    private func beginAssignmentEditing(
        _ category: BudgetMonthCategory,
        scrollTarget: CGFloat?
    ) {
        expandAssignmentScrollClearance()

        guard let scrollTarget else {
            withAnimation(BudgetLayout.assignmentKeypadAnimation) {
                viewModel.beginAssignmentEditing(for: category)
            }
            return
        }

        if viewModel.isAssignmentKeypadPresented {
            withAnimation(BudgetLayout.assignmentKeypadAnimation) {
                viewModel.beginAssignmentEditing(for: category)
                compactScrollPosition.scrollTo(y: scrollTarget)
            }
            return
        }

        pendingAssignmentOpening = BudgetAssignmentOpeningRequest(
            categoryID: category.id,
            scrollTarget: scrollTarget
        )
    }

    private func expandAssignmentScrollClearance() {
        let expandedPadding = BudgetKeypadLayout.initialHeight
            + BudgetLayout.assignmentScrollBottomClearance
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            assignmentScrollBottomPadding = expandedPadding
        }
    }

    private func beginPreparedAssignmentOpeningIfNeeded() {
        guard let request = pendingAssignmentOpening else {
            return
        }
        pendingAssignmentOpening = nil
        guard let category = realCategory(id: request.categoryID) else {
            assignmentScrollBottomPadding = BudgetLayout.sectionSpacing
            return
        }

        withAnimation(BudgetLayout.assignmentKeypadAnimation) {
            viewModel.beginAssignmentEditing(for: category)
            compactScrollPosition.scrollTo(y: request.scrollTarget)
        }
    }

    private func dismissAssignmentKeypad(_ dismiss: () -> Void) {
        pendingAssignmentOpening = nil
        withAnimation(BudgetLayout.assignmentKeypadAnimation) {
            assignmentScrollBottomPadding = BudgetLayout.sectionSpacing
            dismiss()
        }
    }

    private var loadingState: some View {
        GlassPanel {
            HStack {
                ProgressView()
                Text("Loading budget")
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyState: some View {
        GlassPanel {
            VStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.title)
                    .foregroundStyle(ActualistTheme.accent)
                Text(viewModel.errorMessage ?? "No local budget data is available for this month.")
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
