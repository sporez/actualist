import SwiftUI

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel: BudgetViewModel
    @State private var isTransactionEditorPresented = false
    @State private var isSettingsPresented = false
    @State private var isHistoryPresented = false
    @State private var isMonthPickerPresented = false
    @State private var isUncategorizedTransactionsPresented = false
    @State private var uncategorizedRouteMonth: String?
    @State private var categoryDetailsPresentation: CategoryMonthDetails?
    @State private var isOverspentCategoriesPresented = false
    @State private var assignmentKeypadHeight: CGFloat = 0
    @State private var assignmentScrollTask: Task<Void, Never>?
    @State private var assignmentEditingCategoryFrame: CGRect = .zero
    @State private var assignmentKeypadTopY: CGFloat = 0
    @State private var pendingTemplateConfirmation: BudgetTemplateConfirmation?
    @State private var noteTarget: ActualNoteTarget?
    @State private var visibilityWorkflow = BudgetCategoryVisibilityWorkflow()
    @State private var addTransactionExpansion = ScrollDirectedExpansion()

    init(initialMonth: LoadedBudgetMonth? = nil, initialBudgetID: String? = nil) {
        _viewModel = State(
            initialValue: BudgetViewModel(
                initialMonth: initialMonth,
                initialBudgetID: initialBudgetID
            )
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: BudgetLayout.sectionSpacing) {
                        if viewModel.budgetMonth != nil {
                            operationErrorBanner
                            budgetAlertBanners
                            categoryGroups
                        } else if viewModel.isLoading {
                            loadingState
                        } else {
                            emptyState
                        }
                    }
                    .padding(.horizontal, BudgetLayout.screenHorizontalPadding)
                    .padding(.top, 4)
                    .padding(.bottom, scrollBottomPadding)
                }
                .scrollIndicators(.hidden)
                .background(ActualistTheme.background)
                .onScrollGeometryChange(for: ScrollDirectedExpansionSample.self) { geometry in
                    ScrollDirectedExpansionSample(
                        offset: geometry.visibleRect.minY,
                        maxOffset: max(0, geometry.contentSize.height - geometry.visibleRect.height)
                    )
                } action: { previous, current in
                    updateAddTransactionExpansion(previous: previous, current: current)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if viewModel.isAssignmentKeypadPresented {
                        BudgetAssignmentKeypad(
                            canSubmit: viewModel.canSubmitAssignment,
                            showsApplyTemplate: viewModel.activeCategoryHasTemplate,
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
                                withAnimation(BudgetLayout.assignmentKeypadAnimation) {
                                    viewModel.cancelAssignmentEditing()
                                }
                            },
                            deleteDigit: { viewModel.deleteAssignmentDigit() },
                            clearOrCancel: {
                                withAnimation(BudgetLayout.assignmentKeypadAnimation) {
                                    viewModel.clearOrCancelAssignmentInput()
                                }
                            },
                            cancel: {
                                withAnimation(BudgetLayout.assignmentKeypadAnimation) {
                                    viewModel.cancelAssignmentEditing()
                                }
                            },
                            submit: {
                                Task { await viewModel.submitAssignment(using: appState) }
                            }
                        )
                        .readHeight(into: BudgetAssignmentKeypadHeightKey.self)
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear {
                                        assignmentKeypadTopY = geometry.frame(in: .global).minY
                                    }
                                    .onChange(of: geometry.frame(in: .global).minY) { _, top in
                                        assignmentKeypadTopY = top
                                    }
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onPreferenceChange(BudgetAssignmentKeypadHeightKey.self) { height in
                    assignmentKeypadHeight = height
                    if height > 0,
                       let categoryID = viewModel.activeAssignmentCategoryID {
                        scheduleAssignmentCategoryScroll(categoryID, using: scrollProxy)
                    }
                }
                .animation(BudgetLayout.assignmentKeypadAnimation, value: viewModel.isAssignmentKeypadPresented)
                .overlay(alignment: .bottomTrailing) {
                    if !viewModel.isAssignmentKeypadPresented {
                        BudgetAddTransactionButton(isExpanded: addTransactionExpansion.isExpanded) {
                            isTransactionEditorPresented = true
                        }
                        .padding(.trailing, BudgetLayout.screenHorizontalPadding)
                        .padding(.bottom, BudgetLayout.addTransactionFloatingPadding)
                    }
                }
                .navigationTitle(viewModel.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isSettingsPresented = true
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
                            .appSwitcherPrivacyProtected()
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
                .task { await viewModel.load(using: appState) }
                .refreshable { await viewModel.refresh(using: appState) }
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
                .sheet(isPresented: $isTransactionEditorPresented) {
                    TransactionEditorView(prefilledAccount: nil) {
                        Task { await viewModel.refreshSelectedMonth(using: appState) }
                    }
                        .environment(appState)
                        .appSwitcherPrivacyProtected()
                }
                .sheet(isPresented: $isHistoryPresented) {
                    HistoryView()
                        .environment(appState)
                        .appSwitcherPrivacyProtected()
                }
                .fullScreenCover(isPresented: $isSettingsPresented) {
                    SettingsView(showsDismissButton: true)
                        .environment(appState)
                        .appSwitcherPrivacyProtected()
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
                    .environment(appState)
                    .appSwitcherPrivacyProtected()
                }
                .sheet(item: $categoryDetailsPresentation, onDismiss: {
                    Task { await viewModel.refreshSelectedMonth(using: appState) }
                }) { details in
                    CategoryMonthDetailsView(details: details)
                        .environment(appState)
                        .appSwitcherPrivacyProtected()
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
                        .appSwitcherPrivacyProtected()
                    }
                }
                .sheet(isPresented: $isOverspentCategoriesPresented) {
                    BudgetOverspentCategoriesView(
                        viewModel: viewModel,
                        isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled
                    )
                    .environment(appState)
                    .appSwitcherPrivacyProtected()
                }
                .sheet(isPresented: moveMoneyPresentationBinding) {
                    BudgetMoveMoneyView(
                        viewModel: viewModel,
                        onSaved: {}
                    )
                        .environment(appState)
                        .appSwitcherPrivacyProtected()
                }
                .modifier(
                    BudgetTemplateConfirmationModifier(
                        confirmation: $pendingTemplateConfirmation,
                        apply: applyTemplate
                    )
                )
                .onChange(of: viewModel.activeAssignmentCategoryID) { _, categoryID in
                    if let categoryID {
                        scheduleAssignmentCategoryScroll(categoryID, using: scrollProxy)
                    } else {
                        assignmentScrollTask?.cancel()
                        assignmentScrollTask = nil
                        assignmentKeypadTopY = 0
                        assignmentEditingCategoryFrame = .zero
                    }
                }
            }
        }
    }

    private func applyTemplate(_ confirmation: BudgetTemplateConfirmation) {
        switch confirmation {
        case .monthFillEmpty:
            Task { await viewModel.applyMonthTemplate(.fillEmpty, using: appState) }
        case .monthOverwrite:
            Task { await viewModel.applyMonthTemplate(.overwrite, using: appState) }
        case .category:
            Task { await viewModel.applyCategoryTemplate(using: appState) }
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

    private var scrollBottomPadding: CGFloat {
        guard viewModel.isAssignmentKeypadPresented else {
            return 28
        }

        return max(assignmentKeypadHeight + BudgetLayout.assignmentScrollBottomClearance, 360)
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

    private var displayedBudgetMonth: BudgetMonth? {
        BudgetMonthPrivacyProjection.displayMonth(
            viewModel.budgetMonth,
            isEnabled: appState.settings.randomizedDisplayValuesEnabled,
            currency: viewModel.currency
        )
    }

    private var displayedGroups: [BudgetMonthCategoryGroup] {
        BudgetCategoryVisibility.displayedGroups(
            from: displayedBudgetMonth?.categoryGroups ?? [],
            showHidden: appState.settings.showHiddenCategories
        )
    }

    private var showHiddenCategoriesBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.showHiddenCategories },
            set: { appState.updateShowHiddenCategories($0) }
        )
    }

    private var displayedBudgetAlerts: [BudgetAlert] {
        BudgetMonthSummaryPresentation.alerts(
            from: viewModel.budgetAlerts,
            month: displayedBudgetMonth,
            showTotalAssigned: appState.settings.showTotalAssigned,
            includeCarryoverInOverspent: appState.settings.includeCarryoverCategoriesInOverspentAlerts,
            isTrackingBudget: viewModel.isTrackingBudget,
            currency: viewModel.currency
        )
    }

    private var budgetAlertBanners: some View {
        ForEach(displayedBudgetAlerts) { alert in
            if alert.isActionable {
                Button {
                    open(alert)
                } label: {
                    budgetAlertLabel(alert)
                }
                .buttonStyle(.plain)
            } else {
                budgetAlertLabel(alert)
            }
        }
    }

    private func budgetAlertLabel(_ alert: BudgetAlert) -> some View {
        BudgetAlertBanner(
            alert: alert,
            assignedText: assignedDisplayText(for: alert)
        )
    }

    private func assignedDisplayText(for alert: BudgetAlert) -> String? {
        BudgetMonthSummaryPresentation.assignedValueText(
            for: alert,
            month: displayedBudgetMonth,
            showTotalAssigned: appState.settings.showTotalAssigned,
            currency: viewModel.currency
        )
    }

    private func applyShortcutRoute() {
        if case .settings = appState.routeCoordinator.pendingRoute {
            isSettingsPresented = true
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
            month: applied.month
        )
    }

    private func realExpenseCategory(id: String) -> BudgetMonthCategory? {
        viewModel.budgetMonth?.categoryGroups
            .filter { !$0.isIncome }
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

    private var categoryGroups: some View {
        LazyVStack(spacing: 0, pinnedViews: []) {
            ForEach(displayedGroups) { group in
                BudgetGroupSection(
                    group: group,
                    isExpanded: viewModel.isExpanded(group),
                    isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                    assignedDisplay: { category in
                        viewModel.assignedAmountDisplay(for: category)
                    },
                    isEditingAssignment: { category in
                        viewModel.isEditingAssignment(for: category)
                    },
                    beginAssignmentEditing: { category, categoryFrame in
                        guard let realCategory = realExpenseCategory(id: category.id) else {
                            return
                        }
                        assignmentEditingCategoryFrame = categoryFrame
                        withAnimation(.smooth(duration: 0.16)) {
                            viewModel.beginAssignmentEditing(for: realCategory)
                        }
                    },
                    toggle: {
                        withAnimation(.smooth(duration: 0.2)) {
                            viewModel.toggle(group)
                        }
                    },
                    showHidden: appState.settings.showHiddenCategories,
                    hidesCarryoverArrows: appState.settings.hideCarryoverArrows,
                    canChangeVisibility: !visibilityWorkflow.isSubmitting,
                    onOpenCategoryNote: { category in
                        noteTarget = ActualNoteTarget.category(
                            id: category.id,
                            title: category.name.actualistCategoryNameParts.name
                        )
                    },
                    onOpenGroupNote: {
                        noteTarget = ActualNoteTarget.categoryGroup(
                            id: group.id,
                            title: group.name
                        )
                    },
                    onToggleCategoryHidden: { category in
                        toggleCategoryHidden(category, in: group)
                    },
                    onToggleGroupHidden: {
                        toggleGroupHidden(group)
                    }
                )
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

    private func scheduleAssignmentCategoryScroll(
        _ categoryID: String,
        using scrollProxy: ScrollViewProxy
    ) {
        assignmentScrollTask?.cancel()
        assignmentScrollTask = Task { @MainActor in
            for delay in BudgetLayout.assignmentScrollDelays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    await Task.yield()
                }

                guard !Task.isCancelled,
                      viewModel.activeAssignmentCategoryID == categoryID,
                      viewModel.isAssignmentKeypadPresented else {
                    return
                }

                // Wait for the keypad's measured frame.
                guard assignmentKeypadTopY > 0 else {
                    continue
                }

                // Do not disturb rows already clear of the keypad.
                let occlusionLine = assignmentKeypadTopY - BudgetLayout.assignmentScrollVisibilityMargin
                guard assignmentEditingCategoryFrame.maxY > occlusionLine else {
                    return
                }

                withAnimation(BudgetLayout.assignmentScrollAnimation) {
                    scrollProxy.scrollTo(BudgetScrollTarget.assignmentAnchor(categoryID), anchor: .bottom)
                }
            }
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
