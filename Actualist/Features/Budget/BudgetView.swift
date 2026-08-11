import SwiftUI

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel: BudgetViewModel
    @State private var isTransactionEditorPresented = false
    @State private var isSettingsPresented = false
    @State private var isMonthPickerPresented = false
    @State private var isUncategorizedTransactionsPresented = false
    @State private var categoryDetailsPresentation: CategoryMonthDetails?
    @State private var isOverspentCategoriesPresented = false
    @State private var pendingOverspentCategoryID: String?
    @State private var activeOverspentCoverCategoryID: String?
    @State private var shouldContinueOverspentCoverFlow = false
    @State private var assignmentKeypadHeight: CGFloat = 0
    @State private var assignmentScrollTask: Task<Void, Never>?
    @State private var assignmentEditingCategoryFrame: CGRect = .zero
    @State private var assignmentKeypadTopY: CGFloat = 0
    @State private var pendingTemplateConfirmation: BudgetTemplateConfirmation?

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
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if viewModel.isAssignmentKeypadPresented {
                        BudgetAssignmentKeypad(
                            canSubmit: viewModel.canSubmitAssignment,
                            showsTemplateAction: appState.isExperimentalFeatureEnabled(.budgetTemplates),
                            canApplyTemplate: viewModel.canApplyCategoryTemplate && appState.canApplyBudgetTemplates,
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
                .navigationTitle(viewModel.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isTransactionEditorPresented = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .actualistToolbarGlassButton()
                    }

                    ToolbarItem(placement: .principal) {
                        Button {
                            isMonthPickerPresented.toggle()
                        } label: {
                            HStack(spacing: 7) {
                                ConnectionStatusDot(status: appState.connectionStatus)
                                Text(viewModel.navigationTitle)
                                    .font(.headline.weight(.bold))
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
                        if appState.isExperimentalFeatureEnabled(.budgetTemplates) {
                            Menu {
                                Button {
                                    pendingTemplateConfirmation = .monthFillEmpty
                                } label: {
                                    Label("Apply Template", systemImage: "sparkles")
                                }
                                .disabled(viewModel.isApplyingMonthTemplate || !appState.canApplyBudgetTemplates)

                                Button {
                                    pendingTemplateConfirmation = .monthOverwrite
                                } label: {
                                    Label("Apply Template Overwrite", systemImage: "sparkles.square.filled.on.square")
                                }
                                .disabled(viewModel.isApplyingMonthTemplate || !appState.canApplyBudgetTemplates)

                                Divider()

                                Button {
                                    isSettingsPresented = true
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .actualistToolbarGlassButton()
                            .accessibilityLabel("Budget Actions")
                        } else {
                            Button {
                                isSettingsPresented = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .actualistToolbarGlassButton()
                            .accessibilityLabel("Settings")
                        }
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
                .sheet(isPresented: $isTransactionEditorPresented) {
                    TransactionEditorView(prefilledAccount: nil) {
                        Task { await viewModel.refreshSelectedMonth(using: appState) }
                    }
                        .environment(appState)
                        .appSwitcherPrivacyProtected()
                }
                .sheet(isPresented: $isSettingsPresented) {
                    SettingsView(showsDismissButton: true)
                        .environment(appState)
                        .appSwitcherPrivacyProtected()
                }
                .sheet(isPresented: $isUncategorizedTransactionsPresented) {
                    UncategorizedTransactionsView(
                        month: viewModel.selectedMonth ?? viewModel.preferredMonth,
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
                .sheet(
                    isPresented: $isOverspentCategoriesPresented,
                    onDismiss: openPendingOverspentCategory
                ) {
                    BudgetOverspentCategoriesView(
                        categories: viewModel.overspentCategoryOptions,
                        isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled
                    ) { category in
                        pendingOverspentCategoryID = category.id
                    }
                    .appSwitcherPrivacyProtected()
                }
                .sheet(
                    isPresented: moveMoneyPresentationBinding,
                    onDismiss: handleMoveMoneyDismiss
                ) {
                    BudgetMoveMoneyView(
                        viewModel: viewModel,
                        onSaved: handleMoveMoneySaved
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
        if let message = viewModel.errorMessage {
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

    private var budgetAlertBanners: some View {
        ForEach(viewModel.budgetAlerts) { alert in
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
        HStack(spacing: 10) {
            if let valueText = alert.valueText {
                Text(displayAlertValueText(alert, fallback: valueText))
                    .font(ActualistTypography.workScreenAmount(for: density))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if let count = alert.count {
                Text("\(count)")
                    .font(ActualistTypography.control(for: density))
                    .foregroundStyle(alert.countForeground)
                    .frame(width: 28, height: 28)
                    .background(alert.countBackground, in: Circle())
            }

            Text(alert.title)
                .font(ActualistTypography.body(for: density))
                .lineLimit(1)
                .minimumScaleFactor(0.86)

            Spacer()

            if let actionTitle = alert.actionTitle {
                Text(actionTitle)
                    .font(ActualistTypography.control(for: density))
                    .lineLimit(1)
            }

            if alert.isActionable {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
            }
        }
        .foregroundStyle(alert.foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            alert.backgroundView
        }
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
            month: viewModel.selectedMonth ?? viewModel.preferredMonth
        )
    }

    private func displayAlertValueText(_ alert: BudgetAlert, fallback: String) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return fallback
        }

        let signSource = alert.severity == .danger ? -1 : 1
        return PrivacyDisplay.money(
            signSource,
            seed: "budget-alert-\(alert.id)-\(viewModel.selectedMonth ?? viewModel.preferredMonth)",
            maximumDollars: 900
        )
    }

    private func openPendingOverspentCategory() {
        guard let categoryID = pendingOverspentCategoryID else {
            return
        }

        pendingOverspentCategoryID = nil
        Task { @MainActor in
            await Task.yield()
            viewModel.beginMoveMoney(for: categoryID)
            activeOverspentCoverCategoryID = viewModel.isMoveMoneyPresented ? categoryID : nil
        }
    }

    private func handleMoveMoneySaved() {
        guard activeOverspentCoverCategoryID != nil else {
            return
        }

        shouldContinueOverspentCoverFlow = !viewModel.overspentCategoryOptions.isEmpty
        activeOverspentCoverCategoryID = nil
    }

    private func handleMoveMoneyDismiss() {
        activeOverspentCoverCategoryID = nil

        guard shouldContinueOverspentCoverFlow else {
            return
        }

        shouldContinueOverspentCoverFlow = false
        Task { @MainActor in
            await Task.yield()
            if !viewModel.overspentCategoryOptions.isEmpty {
                isOverspentCategoriesPresented = true
            }
        }
    }

    private var categoryGroups: some View {
        LazyVStack(spacing: 0, pinnedViews: []) {
            ForEach(viewModel.visibleGroups) { group in
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
                        assignmentEditingCategoryFrame = categoryFrame
                        withAnimation(.smooth(duration: 0.16)) {
                            viewModel.beginAssignmentEditing(for: category)
                        }
                    },
                    toggle: {
                        withAnimation(.smooth(duration: 0.2)) {
                            viewModel.toggle(group)
                        }
                    }
                )
            }
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
