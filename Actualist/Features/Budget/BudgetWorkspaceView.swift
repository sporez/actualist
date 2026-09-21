import SwiftUI

struct BudgetWorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.budgetRootWidth) private var rootWidth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var viewport: BudgetViewportModel
    let compactModel: BudgetViewModel
    @State private var actions: BudgetWorkspaceActions
    @State private var isMonthPickerPresented = false

    init(viewport: BudgetViewportModel, compactModel: BudgetViewModel) {
        self.viewport = viewport
        self.compactModel = compactModel
        _actions = State(initialValue: BudgetWorkspaceActions(viewport: viewport))
    }

    var body: some View {
        let display = BudgetGridPresentation(
            visibleMonths: viewport.visibleMonths,
            snapshots: viewport.monthSnapshots,
            errors: viewport.monthErrors,
            privacyEnabled: appState.settings.randomizedDisplayValuesEnabled,
            showHidden: appState.settings.showHiddenCategories,
            showTotalAssigned: appState.settings.showTotalAssigned,
            includeCarryover: appState.settings.includeCarryoverCategoriesInOverspentAlerts
        )
        NavigationStack {
            GeometryReader { geometry in
                let inputs = BudgetLayoutInputs(
                    rootWidth: rootWidth,
                    budgetDetailWidth: geometry.size.width,
                    dynamicTypeScale: dynamicTypeSize.budgetLayoutScale,
                    preference: appState.settings.monthDisplayPreference,
                    density: appState.settings.displayDensity
                )
                let capacity = BudgetLayoutMetrics.resolve(inputs)
                let metrics = BudgetLayoutMetrics.resolve(inputs, renderedMonthCount: viewport.resolvedMonthCount)
                VStack(spacing: 0) {
                    if let error = viewport.errorMessage ?? actions.errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(ActualistTheme.danger)
                            .padding()
                    }
                    if viewport.visibleMonths.isEmpty && viewport.isLoading {
                        ProgressView("Loading budget")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        BudgetGridView(
                            viewport: viewport,
                            actions: actions,
                            presentation: display,
                            metrics: metrics
                        )
                            .overlay {
                                if display.groups.isEmpty && !viewport.isLoading {
                                    ContentUnavailableView("No categories", systemImage: "list.bullet.rectangle", description: Text("This budget has no visible categories."))
                                }
                            }
                    }
                }
                .task(id: LoadID(budgetID: appState.settings.selectedBudgetID, count: capacity.visibleMonthCount, route: appState.routeCoordinator.pendingRoute)) {
                    await actions.activate(using: appState, compactModel: compactModel, monthCount: capacity.visibleMonthCount)
                }
            }
            .background(ActualistTheme.background)
            .refreshable { await actions.refresh(using: appState) }
            .onChange(of: viewport.assignmentWorkflow.completionRevision) {
                Task { await viewport.refreshVisibleMonths() }
            }
            .onChange(of: appState.localDataRevision) {
                Task { await viewport.refreshVisibleMonths() }
            }
            .onChange(of: appState.settings.showHiddenCategories, initial: true) { _, showHidden in
                viewport.setShowHidden(showHidden)
            }
            .onChange(of: appState.settings.includeCarryoverCategoriesInOverspentAlerts, initial: true) { _, enabled in
                actions.updateIncludeCarryover(enabled)
            }
            .modifier(BudgetWorkspaceSheets(actions: actions, viewport: viewport))
            .inspector(isPresented: Binding(
                get: { viewport.selectedCategoryDetails != nil },
                set: { if !$0 { viewport.closeInspector() } }
            )) {
                if let details = viewport.selectedCategoryDetails {
                    CategoryMonthDetailsContent(
                        details: details,
                        presentation: .categoryInspector(onClose: viewport.closeInspector)
                    )
                    .id(details.id)
                    .accessibilityIdentifier("budget-category-inspector")
                    .inspectorColumnWidth(min: 340, ideal: 380, max: 440)
                    .appSwitcherPrivacyProtected(using: appState)
                }
            }
            .navigationTitle(display.rangeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { navigationToolbar(display) }
        }
    }

    @ToolbarContentBuilder
    private func navigationToolbar(_ display: BudgetGridPresentation) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { Task { await viewport.moveAnchor(by: -1) } } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous month")
            .keyboardShortcut("[", modifiers: .command)
            Button { Task { await viewport.moveAnchor(by: 1) } } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next month")
            .keyboardShortcut("]", modifiers: .command)
        }
        ToolbarItem(placement: .principal) {
            Button { isMonthPickerPresented = true } label: {
                HStack(spacing: 6) {
                    ConnectionStatusDot(status: appState.connectionStatus, isDemo: appState.isDemoMode)
                    Text(display.rangeTitle).font(.headline)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }
            .accessibilityLabel("Choose budget month, \(display.rangeTitle)")
            .popover(isPresented: $isMonthPickerPresented) {
                BudgetMonthPicker(
                    availableMonths: viewport.visibleSnapshots.first?.availableMonths ?? [],
                    selectedMonth: viewport.anchorMonth,
                    allowsUnlistedMonths: true
                ) { month in
                    isMonthPickerPresented = false
                    if let budgetID = appState.settings.selectedBudgetID {
                        Task { await viewport.load(budgetID: budgetID, anchorMonth: month) }
                    }
                }
                .presentationCompactAdaptation(.popover)
                .appSwitcherPrivacyProtected(using: appState)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Today") { Task { await viewport.jumpToCurrentMonth() } }
                .accessibilityLabel("Current month")
            Menu {
                if !appState.settings.randomizedDisplayValuesEnabled {
                    Button("New Category…", systemImage: "plus") {
                        actions.openCreateCategory()
                    }
                    .disabled(BudgetCategoryLifecycleController.manageableGroups(
                        viewport.visibleSnapshots.first?.month.categoryGroups ?? [],
                        isTrackingBudget: viewport.isTrackingBudget
                    ).isEmpty)
                    .accessibilityIdentifier("budget-new-category")
                    Button("New Group…", systemImage: "folder.badge.plus") {
                        actions.openCreateGroup()
                    }
                    .accessibilityIdentifier("budget-new-group")
                    Divider()
                }
                Picker("Months Shown", selection: Binding(
                    get: { appState.settings.monthDisplayPreference },
                    set: { appState.updateMonthDisplayPreference($0) }
                )) {
                    ForEach(MonthDisplayPreference.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Button("History", systemImage: "clock.arrow.circlepath") { actions.openHistory() }
                Toggle("Show Hidden Categories", isOn: Binding(
                    get: { appState.settings.showHiddenCategories },
                    set: { appState.updateShowHiddenCategories($0) }
                ))
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Budget Actions")
        }
    }

    private struct LoadID: Equatable {
        let budgetID: String?
        let count: Int
        let route: AppRoute?
    }
}
