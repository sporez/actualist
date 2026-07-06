import SwiftUI

private enum BudgetTemplateConfirmation: String, Identifiable {
    case monthFillEmpty
    case monthOverwrite
    case category

    var id: String { rawValue }

    var actionTitle: String {
        switch self {
        case .monthFillEmpty:
            "Apply Template"
        case .monthOverwrite:
            "Apply Template Overwrite"
        case .category:
            "Apply Category Template"
        }
    }

    var message: String {
        switch self {
        case .monthFillEmpty:
            "This will apply the budget template to empty categories for this month."
        case .monthOverwrite:
            "This will overwrite this month's category budget amounts with the budget template."
        case .category:
            "This will apply the template to the selected category."
        }
    }

    var buttonRole: ButtonRole? {
        switch self {
        case .monthOverwrite, .category:
            .destructive
        case .monthFillEmpty:
            nil
        }
    }

    var buttonTint: Color {
        switch self {
        case .monthOverwrite, .category:
            ActualistTheme.danger
        case .monthFillEmpty:
            ActualistTheme.positive
        }
    }
}

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = BudgetViewModel()
    @State private var isTransactionEditorPresented = false
    @State private var isMonthPickerPresented = false
    @State private var isUncategorizedTransactionsPresented = false
    @State private var isOverspentCategoriesPresented = false
    @State private var pendingOverspentCategoryID: String?
    @State private var activeOverspentCoverCategoryID: String?
    @State private var shouldContinueOverspentCoverFlow = false
    @State private var assignmentKeypadHeight: CGFloat = 0
    @State private var assignmentScrollTask: Task<Void, Never>?
    @State private var assignmentEditingCategoryFrame: CGRect = .zero
    @State private var assignmentKeypadTopY: CGFloat = 0
    @State private var pendingTemplateConfirmation: BudgetTemplateConfirmation?

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
                    if viewModel.isAssignmentKeypadPresented && appState.capabilities.canAssignCategoryBudget {
                        BudgetAssignmentKeypad(
                            canSubmit: viewModel.canSubmitAssignment,
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
                        .disabled(!appState.capabilities.canCreateTransactions)
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
                                allowsUnlistedMonths: appState.capabilities.isLocalFirst
                            ) { month in
                                isMonthPickerPresented = false
                                Task { await viewModel.selectMonth(month, using: appState) }
                            }
                            .presentationCompactAdaptation(.popover)
                        }
                    }

                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                Task { await viewModel.load(using: appState) }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }

                            Divider()

                            Button {
                                pendingTemplateConfirmation = .monthFillEmpty
                            } label: {
                                Label("Apply Template", systemImage: "sparkles")
                            }
                            .disabled(viewModel.isApplyingMonthTemplate || !appState.capabilities.canApplyBudgetTemplates)

                            Button {
                                pendingTemplateConfirmation = .monthOverwrite
                            } label: {
                                Label("Apply Template Overwrite", systemImage: "sparkles.square.filled.on.square")
                            }
                            .disabled(viewModel.isApplyingMonthTemplate || !appState.capabilities.canApplyBudgetTemplates)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .actualistToolbarGlassButton()
                    }
                }
                .task { await viewModel.load(using: appState) }
                .refreshable { await viewModel.load(using: appState) }
                .onChange(of: appState.selectedTab) { _, tab in
                    // Edits on other tabs invalidate the cached month; revalidate when the
                    // Budget tab becomes active so its numbers are never stale.
                    if tab == .budget {
                        Task { await viewModel.refreshSelectedMonth(using: appState) }
                    }
                }
                .sheet(isPresented: $isTransactionEditorPresented) {
                    TransactionEditorView(prefilledAccount: nil) {
                        Task { await viewModel.refreshSelectedMonth(using: appState) }
                    }
                        .environment(appState)
                }
                .sheet(isPresented: $isUncategorizedTransactionsPresented) {
                    UncategorizedTransactionsView(
                        month: viewModel.selectedMonth ?? viewModel.preferredMonth,
                        onChanged: {
                            Task { await viewModel.refreshSelectedMonth(using: appState) }
                        },
                        onResolvedAll: {
                            isUncategorizedTransactionsPresented = false
                        }
                    )
                    .environment(appState)
                }
                .sheet(
                    isPresented: $isOverspentCategoriesPresented,
                    onDismiss: openPendingOverspentCategory
                ) {
                    BudgetOverspentCategoriesView(
                        categories: viewModel.overspentCategoryOptions,
                        isReadOnly: !appState.capabilities.canMoveMoney,
                        isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled
                    ) { category in
                        pendingOverspentCategoryID = category.id
                    }
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
                        guard appState.capabilities.canAssignCategoryBudget else {
                            return
                        }
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

                // Wait until the keypad has laid out and reported its real
                // top edge before deciding anything.
                guard assignmentKeypadTopY > 0 else {
                    continue
                }

                // Only scroll if the tapped category would actually be hidden
                // behind the keypad. If it's already fully above the keypad,
                // leave the scroll position alone.
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
                Text(viewModel.errorMessage ?? "Budget data will appear after Actualist connects.")
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ConnectionStatusDot: View {
    let status: ServerConnectionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.65), lineWidth: 0.75)
            }
            .shadow(color: color.opacity(0.55), radius: 4)
            .accessibilityLabel(accessibilityLabel)
    }

    private var color: Color {
        switch status {
        case .online:
            Color(red: 0.22, green: 0.82, blue: 0.38)
        case .connecting:
            Color(red: 0.96, green: 0.76, blue: 0.20)
        case .offline:
            Color(red: 0.95, green: 0.26, blue: 0.32)
        }
    }

    private var accessibilityLabel: String {
        switch status {
        case .online:
            "Server connected"
        case .connecting:
            "Server connecting"
        case .offline:
            "Server offline, read only"
        }
    }
}

private extension BudgetAlert {
    var isActionable: Bool {
        switch kind {
        case .uncategorizedTransactions, .overspending:
            true
        case .toBudget:
            false
        }
    }

    var foreground: Color {
        switch severity {
        case .positive:
            .black.opacity(0.78)
        case .warning, .danger:
            ActualistTheme.primaryText
        }
    }

    @ViewBuilder
    var backgroundView: some View {
        switch severity {
        case .positive:
            Capsule().fill(ActualistTheme.positive)
        case .warning, .danger:
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ActualistTheme.surface)
        }
    }

    var countForeground: Color {
        switch severity {
        case .positive:
            .black.opacity(0.78)
        case .warning:
            .black.opacity(0.78)
        case .danger:
            .white
        }
    }

    var countBackground: Color {
        switch severity {
        case .positive:
            ActualistTheme.positive
        case .warning:
            ActualistTheme.warning
        case .danger:
            ActualistTheme.danger.opacity(0.8)
        }
    }
}

private struct BudgetOverspentCategoriesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    let categories: [BudgetOverspentCategoryOption]
    let isReadOnly: Bool
    let isPrivacyModeEnabled: Bool
    let onSelect: (BudgetOverspentCategoryOption) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if categories.isEmpty {
                            GlassPanel {
                                VStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(ActualistTheme.positive)
                                    Text("No overspent categories")
                                        .font(ActualistTypography.rowTitle(for: density))
                                        .foregroundStyle(ActualistTheme.primaryText)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(categories) { category in
                                    Button {
                                        guard !isReadOnly else {
                                            return
                                        }
                                        onSelect(category)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(categoryName(category))
                                                    .font(ActualistTypography.rowTitle(for: density))
                                                    .foregroundStyle(ActualistTheme.primaryText)
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.84)

                                                Text(groupName(category))
                                                    .font(ActualistTypography.rowBadge(for: density))
                                                    .foregroundStyle(ActualistTheme.secondaryText)
                                            }

                                            Spacer()

                                            Text(amountText(category))
                                                .font(ActualistTypography.rowValue(for: density))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.78)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(ActualistTheme.danger.opacity(0.84), in: Capsule())

                                            Image(systemName: "chevron.right")
                                                .font(.subheadline.weight(.bold))
                                                .foregroundStyle(ActualistTheme.secondaryText)
                                        }
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 14)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if category.id != categories.last?.id {
                                        Divider()
                                            .overlay(ActualistTheme.separator)
                                            .padding(.leading, 18)
                                    }
                                }
                            }
                            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Cover Overspending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func categoryName(_ category: BudgetOverspentCategoryOption) -> String {
        guard isPrivacyModeEnabled else {
            return category.categoryName
        }

        return PrivacyDisplay.name(for: .category, seed: category.id)
    }

    private func groupName(_ category: BudgetOverspentCategoryOption) -> String {
        guard isPrivacyModeEnabled else {
            return category.groupName
        }

        return PrivacyDisplay.name(for: .categoryGroup, seed: category.groupName)
    }

    private func amountText(_ category: BudgetOverspentCategoryOption) -> String {
        guard isPrivacyModeEnabled else {
            return category.amountText
        }

        return PrivacyDisplay.money(
            category.category.balance,
            seed: "overspent-category-\(category.id)",
            maximumDollars: 900
        )
    }
}

private struct BudgetMonthPicker: View {
    @Environment(\.actualistDensity) private var density

    let availableMonths: [String]
    let selectedMonth: String?
    let allowsUnlistedMonths: Bool
    let onSelect: (String) -> Void

    @State private var displayedYear: Int

    init(
        availableMonths: [String],
        selectedMonth: String?,
        allowsUnlistedMonths: Bool,
        onSelect: @escaping (String) -> Void
    ) {
        self.availableMonths = availableMonths
        self.selectedMonth = selectedMonth
        self.allowsUnlistedMonths = allowsUnlistedMonths
        self.onSelect = onSelect
        _displayedYear = State(initialValue: Self.initialYear(
            selectedMonth: selectedMonth,
            availableMonths: availableMonths
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    displayedYear -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.bold))
                }
                .disabled(!hasPreviousYear)

                Spacer()

                Text(String(displayedYear))
                    .font(ActualistTypography.sectionTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer()

                Button {
                    displayedYear += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.bold))
                }
                .disabled(!hasNextYear)
            }
            .foregroundStyle(ActualistTheme.accent)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().overlay(ActualistTheme.separator)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 18) {
                ForEach(1...12, id: \.self) { monthNumber in
                    let monthID = Self.monthID(year: displayedYear, month: monthNumber)
                    Button {
                        onSelect(monthID)
                    } label: {
                        Text(Self.monthName(for: monthNumber))
                            .font(monthID == selectedMonth ? ActualistTypography.control(for: density) : ActualistTypography.body(for: density))
                            .foregroundStyle(monthTextColor(monthID))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(monthBackground(monthID), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelect(monthID))
                }
            }
            .padding(20)
        }
        .frame(width: 320)
        .background(ActualistTheme.surface)
    }

    private var availableMonthSet: Set<String> {
        Set(availableMonths)
    }

    private var availableYears: [Int] {
        Array(Set(availableMonths.compactMap(Self.year))).sorted()
    }

    private var hasPreviousYear: Bool {
        allowsUnlistedMonths || availableYears.contains(where: { $0 < displayedYear })
    }

    private var hasNextYear: Bool {
        allowsUnlistedMonths || availableYears.contains(where: { $0 > displayedYear })
    }

    private func canSelect(_ monthID: String) -> Bool {
        allowsUnlistedMonths || availableMonthSet.contains(monthID)
    }

    private func monthTextColor(_ monthID: String) -> Color {
        if monthID == selectedMonth {
            return ActualistTheme.primaryText
        }

        return canSelect(monthID) ? ActualistTheme.primaryText : ActualistTheme.secondaryText.opacity(0.36)
    }

    private func monthBackground(_ monthID: String) -> Color {
        monthID == selectedMonth ? ActualistTheme.accent : Color.clear
    }

    private static func initialYear(selectedMonth: String?, availableMonths: [String]) -> Int {
        if let selectedYear = selectedMonth.flatMap(year) {
            return selectedYear
        }

        if let latestYear = availableMonths.compactMap(year).max() {
            return latestYear
        }

        return Calendar(identifier: .gregorian).component(.year, from: Date())
    }

    private static func monthID(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    private static func year(from monthID: String) -> Int? {
        guard monthID.count >= 4 else {
            return nil
        }

        return Int(monthID.prefix(4))
    }

    private static func monthName(for monthNumber: Int) -> String {
        Calendar.current.shortMonthSymbols[monthNumber - 1]
    }
}

private enum BudgetLayout {
    static let screenHorizontalPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 10
    static let chevronWidth: CGFloat = 24
    static let emojiSize: CGFloat = 20
    static let emojiWidth: CGFloat = 26
    static let assignedWidth: CGFloat = 96
    static let availableWidth: CGFloat = 104
    static let availablePillHorizontalPadding: CGFloat = 6
    static let assignmentScrollBottomClearance: CGFloat = 160
    static let assignmentScrollVisibilityMargin: CGFloat = 20
    static let assignmentKeypadAnimation = Animation.smooth(duration: 0.24)
    static let assignmentScrollAnimation = Animation.smooth(duration: 0.22)
    static let assignmentScrollDelays: [UInt64] = [
        0,
        140_000_000,
        280_000_000,
        460_000_000
    ]
}

private struct BudgetTemplateConfirmationModifier: ViewModifier {
    @Binding var confirmation: BudgetTemplateConfirmation?
    let apply: (BudgetTemplateConfirmation) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $confirmation) { confirmation in
            BudgetTemplateConfirmationSheet(
                confirmation: confirmation,
                cancel: {
                    self.confirmation = nil
                },
                apply: {
                    self.confirmation = nil
                    apply(confirmation)
                }
            )
            .presentationDetents([.height(310)])
            .presentationDragIndicator(.visible)
            .presentationBackground(ActualistTheme.background)
        }
    }
}

private struct BudgetTemplateConfirmationSheet: View {
    let confirmation: BudgetTemplateConfirmation
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("Are you sure?")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .multilineTextAlignment(.center)

                Text(confirmation.message)
                    .font(.subheadline)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button(role: confirmation.buttonRole) {
                    apply()
                } label: {
                    Text(confirmation.actionTitle)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent)
                .tint(confirmation.buttonTint)

                Button(role: .cancel) {
                    cancel()
                } label: {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }
}

private enum BudgetScrollTarget {
    static func category(_ categoryID: String) -> String {
        "budget-category-\(categoryID)"
    }

    static func assignmentAnchor(_ categoryID: String) -> String {
        "budget-assignment-anchor-\(categoryID)"
    }
}

private enum BudgetKeypadLayout {
    static let keyHeight: CGFloat = 46
    static let keyPressHighlightWidth: CGFloat = 74
    static let keyPressHighlightHeight: CGFloat = 44
    static let actionHeight: CGFloat = 54
    static let toolbarButtonHeight: CGFloat = 68
    static let stackSpacing: CGFloat = 14
    static let gridHorizontalSpacing: CGFloat = 22
    static let gridVerticalSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 22
    static let dismissButtonWidth: CGFloat = 52
}

private struct BudgetAssignmentKeypadHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func readHeight<Key: PreferenceKey>(into key: Key.Type) -> some View where Key.Value == CGFloat {
        overlay {
            GeometryReader { geometry in
                Color.clear.preference(key: key, value: geometry.size.height)
            }
        }
    }
}

private struct BudgetKeypadPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule(style: .continuous)
                    .fill(ActualistTheme.control)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(ActualistTheme.separator, lineWidth: 1)
                    }
                    .frame(
                        width: BudgetKeypadLayout.keyPressHighlightWidth,
                        height: BudgetKeypadLayout.keyPressHighlightHeight
                    )
                    .opacity(configuration.isPressed ? 1 : 0)
                    .scaleEffect(configuration.isPressed ? 1 : 0.82)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct BudgetGroupSection: View {
    @Environment(\.actualistDensity) private var density

    let group: BudgetMonthCategoryGroup
    let isExpanded: Bool
    let isPrivacyModeEnabled: Bool
    let assignedDisplay: (BudgetMonthCategory) -> BudgetAssignedAmountDisplay
    let isEditingAssignment: (BudgetMonthCategory) -> Bool
    let beginAssignmentEditing: (BudgetMonthCategory, CGRect) -> Void
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: BudgetLayout.rowSpacing) {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .font(.body.weight(.bold))
                        .frame(width: BudgetLayout.chevronWidth)

                    Text(groupName)
                        .font(ActualistTypography.sectionTitle(for: density))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Assigned")
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(groupBudgetedText)
                            .font(ActualistTypography.rowValue(for: density))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(width: BudgetLayout.assignedWidth, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Available")
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(groupBalanceText)
                            .font(ActualistTypography.rowValue(for: density))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(width: BudgetLayout.availableWidth, alignment: .trailing)
                }
                .foregroundStyle(ActualistTheme.primaryText)
                .padding(.vertical, 12)
                .padding(.horizontal, BudgetLayout.rowHorizontalPadding)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(group.visibleCategories.enumerated()), id: \.element.id) { index, category in
                        BudgetCategoryRow(
                            category: category,
                            assignedDisplay: assignedDisplay(category),
                            isEditing: isEditingAssignment(category),
                            isPrivacyModeEnabled: isPrivacyModeEnabled,
                            showsBottomSeparator: index < group.visibleCategories.count - 1,
                            beginAssignmentEditing: { categoryFrame in
                                beginAssignmentEditing(category, categoryFrame)
                            }
                        )
                        .id(BudgetScrollTarget.category(category.id))
                        .overlay(alignment: .bottom) {
                            Color.clear
                                .frame(height: 1)
                                .id(BudgetScrollTarget.assignmentAnchor(category.id))
                        }
                    }
                }
                .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var groupName: String {
        guard isPrivacyModeEnabled else {
            return group.name
        }

        return PrivacyDisplay.name(for: .categoryGroup, seed: group.id)
    }

    private var groupBudgetedText: String {
        guard isPrivacyModeEnabled else {
            return group.budgeted.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            group.budgeted,
            seed: "budget-group-budgeted-\(group.id)",
            maximumDollars: 2_500
        )
    }

    private var groupBalanceText: String {
        guard isPrivacyModeEnabled else {
            return group.balance.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            group.balance,
            seed: "budget-group-balance-\(group.id)",
            maximumDollars: 2_500
        )
    }
}

struct BudgetCategoryRow: View {
    @Environment(\.actualistDensity) private var density

    let category: BudgetMonthCategory
    let assignedDisplay: BudgetAssignedAmountDisplay
    let isEditing: Bool
    let isPrivacyModeEnabled: Bool
    let showsBottomSeparator: Bool
    let beginAssignmentEditing: (CGRect) -> Void

    @State private var globalFrame: CGRect = .zero

    var body: some View {
        Button {
            if !assignedDisplay.isEditing {
                beginAssignmentEditing(globalFrame)
            }
        } label: {
            HStack(spacing: BudgetLayout.rowSpacing) {
                emojiSlot

                Text(categoryName)
                    .font(ActualistTypography.body(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(assignedPrimaryText)
                        .font(ActualistTypography.rowValue(for: density))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let secondaryText = assignedDisplay.secondaryText {
                        Text(secondaryText)
                            .font(ActualistTypography.rowLabel(for: density).weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
                .foregroundStyle(assignedDisplay.isEditing ? ActualistTheme.accent : ActualistTheme.primaryText)
                .frame(width: BudgetLayout.assignedWidth, alignment: .trailing)

                Text(availableText)
                    .font(ActualistTypography.rowValue(for: density))
                    .foregroundStyle(availableForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, BudgetLayout.availablePillHorizontalPadding)
                    .padding(.vertical, 5)
                    .background(availableBackground, in: Capsule())
                    .frame(width: BudgetLayout.availableWidth, alignment: .trailing)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, BudgetLayout.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        globalFrame = geometry.frame(in: .global)
                    }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in
                        globalFrame = frame
                    }
            }
        }
        .background(isEditing ? ActualistTheme.elevatedSurface : Color.clear)
        .overlay(alignment: .bottom) {
            if showsBottomSeparator {
                Rectangle()
                    .fill(ActualistTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, BudgetLayout.emojiWidth + BudgetLayout.rowSpacing)
            }
        }
    }

    @ViewBuilder
    private var emojiSlot: some View {
        if !isPrivacyModeEnabled, let emoji = nameParts.emoji {
            Text(verbatim: emoji)
                .font(.actualistEmoji(size: BudgetLayout.emojiSize))
                .frame(width: BudgetLayout.emojiWidth, height: BudgetLayout.emojiWidth)
                .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: BudgetLayout.emojiWidth, height: BudgetLayout.emojiWidth)
        }
    }

    private var availableBackground: Color {
        if category.balance < 0 {
            return ActualistTheme.danger
        }
        if category.balance == 0 {
            return ActualistTheme.neutral
        }
        return ActualistTheme.positive
    }

    private var availableForeground: Color {
        category.balance == 0 ? ActualistTheme.secondaryText : .black.opacity(0.78)
    }

    private var nameParts: CategoryNameParts {
        category.name.actualistCategoryNameParts
    }

    private var categoryName: String {
        guard isPrivacyModeEnabled else {
            return nameParts.name
        }

        return PrivacyDisplay.name(for: .category, seed: category.id)
    }

    private var assignedPrimaryText: String {
        guard isPrivacyModeEnabled, !assignedDisplay.isEditing else {
            return assignedDisplay.primaryText
        }

        return PrivacyDisplay.money(
            category.budgeted,
            seed: "budget-category-budgeted-\(category.id)",
            maximumDollars: 900
        )
    }

    private var availableText: String {
        guard isPrivacyModeEnabled else {
            return category.balance.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            category.balance,
            seed: "budget-category-available-\(category.id)",
            maximumDollars: 900
        )
    }
}

private struct BudgetMoveMoneyView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Bindable var viewModel: BudgetViewModel
    let onSaved: () -> Void

    @State private var isDestinationPickerPresented = false
    @State private var didAutoPresentDestinationPicker = false
    @State private var isNumberPadVisible = false

    var body: some View {
        ZStack {
            ActualistTheme.background.ignoresSafeArea()

            if let draft = viewModel.moveMoneyDraft {
                VStack(spacing: 0) {
                    moveHeader(draft)

                    GeometryReader { proxy in
                        VStack(spacing: 12) {
                            ScrollView {
                                VStack(spacing: 18) {
                                    destinationCard(draft)

                                    if let errorMessage = viewModel.activeMoveMoneyErrorMessage {
                                        Text(errorMessage)
                                            .font(ActualistTypography.rowTitle(for: density))
                                            .foregroundStyle(ActualistTheme.danger)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(16)
                                            .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    }
                                }
                                .padding(.bottom, 4)
                            }
                            .scrollIndicators(.hidden)
                            .frame(maxHeight: max(148, proxy.size.height - reservedBottomHeight))

                            if isNumberPadVisible {
                                BudgetMoveMoneyNumberPad(
                                    canSubmit: viewModel.canSubmitMoveMoney,
                                    isSubmitting: viewModel.isSubmittingMoveMoney,
                                    appendDigit: { viewModel.appendMoveMoneyDigit($0) },
                                    deleteDigit: { viewModel.deleteMoveMoneyDigit() },
                                    clear: { viewModel.clearMoveMoneyAmount() },
                                    submit: submitMoveMoney
                                )
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            } else {
                                compactSubmitButton
                            }
                        }
                        .animation(.snappy(duration: 0.24), value: isNumberPadVisible)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, -28)
                    .padding(.bottom, 10)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $isDestinationPickerPresented) {
            BudgetMoveMoneyDestinationPicker(viewModel: viewModel)
                .environment(appState)
        }
        .task(id: viewModel.moveMoneyDraft?.focusedCategoryID) {
            guard !didAutoPresentDestinationPicker else {
                return
            }

            didAutoPresentDestinationPicker = true
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard viewModel.isMoveMoneyPresented,
                  viewModel.moveMoneyDraft?.destination == nil else {
                return
            }

            isDestinationPickerPresented = true
        }
    }

    private var reservedBottomHeight: CGFloat {
        isNumberPadVisible ? BudgetMoveMoneyLayout.numberPadReservedHeight : BudgetMoveMoneyLayout.compactSubmitReservedHeight
    }

    private var compactSubmitButton: some View {
        Button(action: submitMoveMoney) {
            Text(viewModel.isSubmittingMoveMoney ? "saving" : "done")
                .font(ActualistTypography.control(for: density))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(ActualistTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSubmitMoveMoney)
        .opacity(viewModel.canSubmitMoveMoney ? 1 : 0.45)
        .padding(.horizontal, 12)
        .accessibilityLabel("Move money")
    }

    private func submitMoveMoney() {
        Task {
            if await viewModel.submitMoveMoney(using: appState) {
                onSaved()
                dismiss()
            }
        }
    }

    private func moveHeader(_ draft: BudgetMoveMoneyDraft) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 14) {
                Text(draft.direction.headerTitle)
                    .font(ActualistTypography.sectionTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                VStack(spacing: 10) {
                    Text(moveFocusedCategoryName(draft))
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(moveHeaderAmountText(draft))
                        .font(ActualistTypography.workScreenAmount(for: density))
                        .foregroundStyle(moveHeaderAmountForeground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.26), in: Capsule())
                }

                VStack(spacing: 7) {
                    Button {
                        viewModel.toggleMoveMoneyDirection()
                        isNumberPadVisible = false
                        if viewModel.moveMoneyDraft?.destination == nil {
                            isDestinationPickerPresented = true
                        }
                    } label: {
                        Image(systemName: draft.direction.arrowSystemImage)
                            .font(.title.weight(.bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.black.opacity(0.72), Color.white.opacity(0.92))
                            .padding(10)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.isSubmitting)
                    .accessibilityLabel("Switch move money direction")

                    Text(draft.direction.counterpartyPrompt)
                        .font(ActualistTypography.rowLabel(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .padding(.top, 4)

                Spacer(minLength: 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, BudgetMoveMoneyLayout.headerTopInset)
            .padding(.horizontal, BudgetMoveMoneyLayout.headerHorizontalPadding)

            VStack {
                Button {
                    viewModel.cancelMoveMoney()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .frame(width: 54, height: 54)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.isSubmitting)
            }
            .padding(.top, BudgetMoveMoneyLayout.closeButtonTopInset)
            .padding(.leading, BudgetMoveMoneyLayout.closeButtonLeadingInset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 332)
        .background(
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(bottomLeading: 32, bottomTrailing: 32),
                style: .continuous
            )
            .fill(Color(red: 0.14, green: 0.37, blue: 0.04))
        )
    }

    private func destinationCard(_ draft: BudgetMoveMoneyDraft) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Text(moveDestinationTitle(for: draft))
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(draft.destination == nil && draft.allocations.isEmpty ? ActualistTheme.accent : ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Text(moveDisplayAmountText(draft))
                    .font(ActualistTypography.rowValue(for: density))
                    .foregroundStyle(ActualistTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isNumberPadVisible = true
                    }

                Text(moveCounterpartyAvailableText(draft))
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(moveCounterpartyAvailableForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(moveCounterpartyAvailableBackground, in: Capsule())
            }

            if draft.allocations.isEmpty {
                Slider(
                    value: moveAmountDollarsBinding,
                    in: 0...sliderUpperBound,
                    step: 1
                )
                .tint(ActualistTheme.accent)
                .disabled(draft.isSubmitting)
            } else {
                VStack(spacing: 14) {
                    ForEach(draft.allocations) { allocation in
                        moveAllocationRow(allocation, draft: draft)
                    }
                }
            }

            Divider().overlay(ActualistTheme.separator)

            Button {
                isNumberPadVisible = false
                isDestinationPickerPresented = true
            } label: {
                Label(draft.destination == nil ? "Select Category" : "Select Another", systemImage: "plus.circle.fill")
                    .font(ActualistTypography.control(for: density))
                    .foregroundStyle(ActualistTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(draft.isSubmitting)
        }
        .padding(22)
        .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var moveAmountDollarsBinding: Binding<Double> {
        Binding {
            viewModel.moveMoneyAmountDollars
        } set: { value in
            viewModel.setMoveMoneyAmountDollars(value)
        }
    }

    private func moveDestinationTitle(for draft: BudgetMoveMoneyDraft) -> String {
        if !draft.allocations.isEmpty {
            return draft.allocations.count == 1 ? moveAllocationTitle(draft.allocations[0]) : "Selected Categories"
        }

        guard let destination = draft.destination else {
            return "Select Category"
        }

        return moveDestinationTitle(destination)
    }

    private func moveFocusedCategoryName(_ draft: BudgetMoveMoneyDraft) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return draft.focusedCategoryName.actualistCategoryNameParts.name
        }

        return PrivacyDisplay.name(for: .category, seed: draft.focusedCategoryID)
    }

    private func moveHeaderAmountText(_ draft: BudgetMoveMoneyDraft) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return viewModel.moveMoneyAvailableDisplayAmount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            viewModel.moveMoneyAvailableDisplayAmount,
            seed: "move-header-\(draft.focusedCategoryID)",
            maximumDollars: 900
        )
    }

    private func moveDisplayAmountText(_ draft: BudgetMoveMoneyDraft) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return viewModel.moveMoneyDisplayAmount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            viewModel.moveMoneyDisplayAmount,
            seed: "move-display-\(draft.focusedCategoryID)-\(viewModel.moveMoneyDisplayAmount)",
            maximumDollars: 900
        )
    }

    private func moveCounterpartyAvailableText(_ draft: BudgetMoveMoneyDraft) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return viewModel.moveMoneyCounterpartyAvailableDisplayAmount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            viewModel.moveMoneyCounterpartyAvailableDisplayAmount,
            seed: "move-counterparty-\(draft.focusedCategoryID)",
            maximumDollars: 900
        )
    }

    private func moveAllocationTitle(_ allocation: BudgetMoveMoneyAllocation) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return allocation.destination.title
        }

        return moveDestinationTitle(allocation.destination)
    }

    private func moveAllocationAmountText(_ allocation: BudgetMoveMoneyAllocation) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return allocation.amount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            allocation.amount,
            seed: "move-allocation-\(allocation.id)-\(allocation.amount)",
            maximumDollars: 900
        )
    }

    private func moveDestinationTitle(_ destination: BudgetMoveMoneyDestination) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return destination.title
        }

        switch destination {
        case .toBudget:
            return "To Budget"
        case .category(let id, _):
            return PrivacyDisplay.name(for: .category, seed: id)
        }
    }

    private func moveAllocationRow(
        _ allocation: BudgetMoveMoneyAllocation,
        draft: BudgetMoveMoneyDraft
    ) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(moveAllocationTitle(allocation))
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Text(moveAllocationAmountText(allocation))
                    .font(ActualistTypography.rowValue(for: density))
                    .foregroundStyle(ActualistTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.setFocusedMoveMoneyAllocation(allocation.id)
                        isNumberPadVisible = true
                    }
            }

            Slider(
                value: moveAllocationAmountDollarsBinding(for: allocation.id),
                in: 0...sliderUpperBound,
                step: 1
            ) { isEditing in
                if isEditing {
                    viewModel.setFocusedMoveMoneyAllocation(allocation.id)
                    isNumberPadVisible = false
                }
            }
            .tint(ActualistTheme.accent)
            .disabled(draft.isSubmitting)
        }
    }

    private func moveAllocationAmountDollarsBinding(for id: String) -> Binding<Double> {
        Binding {
            guard let allocation = viewModel.moveMoneyDraft?.allocations.first(where: { $0.id == id }) else {
                return 0
            }
            return Double(allocation.amount) / 100
        } set: { value in
            viewModel.setFocusedMoveMoneyAllocation(id)
            viewModel.setMoveMoneyAmountDollars(value)
        }
    }

    private var sliderUpperBound: Double {
        max(1, viewModel.moveMoneyMaximumDollars)
    }

    private var moveCounterpartyAvailableBackground: Color {
        let amount = viewModel.moveMoneyCounterpartyAvailableDisplayAmount
        if amount < 0 {
            return ActualistTheme.danger
        }
        if amount == 0 {
            return ActualistTheme.neutral
        }
        return ActualistTheme.positive
    }

    private var moveCounterpartyAvailableForeground: Color {
        viewModel.moveMoneyCounterpartyAvailableDisplayAmount == 0 ? ActualistTheme.secondaryText : .black.opacity(0.78)
    }

    private var moveHeaderAmountForeground: Color {
        let amount = viewModel.moveMoneyAvailableDisplayAmount
        if amount < 0 {
            return ActualistTheme.danger
        }
        if amount == 0 {
            return ActualistTheme.secondaryText
        }
        return ActualistTheme.primaryText
    }
}

private enum BudgetMoveMoneyLayout {
    static let headerTopInset: CGFloat = 56
    static let closeButtonTopInset: CGFloat = 54
    static let closeButtonLeadingInset: CGFloat = 34
    static let headerHorizontalPadding: CGFloat = 34
    static let numberPadReservedHeight: CGFloat = 302
    static let compactSubmitReservedHeight: CGFloat = 78
}

private struct BudgetMoveMoneyNumberPad: View {
    @Environment(\.actualistDensity) private var density

    let canSubmit: Bool
    let isSubmitting: Bool
    let appendDigit: (Int) -> Void
    let deleteDigit: () -> Void
    let clear: () -> Void
    let submit: () -> Void

    @State private var keyPressCount = 0

    var body: some View {
        Grid(horizontalSpacing: 22, verticalSpacing: 14) {
            GridRow {
                digitButton(7)
                digitButton(8)
                digitButton(9)
            }

            GridRow {
                digitButton(4)
                digitButton(5)
                digitButton(6)
            }

            GridRow {
                digitButton(1)
                digitButton(2)
                digitButton(3)
            }

            GridRow {
                Button {
                    clear()
                    keyPressCount += 1
                } label: {
                    Image(systemName: "xmark.rectangle")
                        .font(ActualistTypography.keypadSymbol(for: density))
                        .foregroundStyle(ActualistTheme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(BudgetKeypadPressStyle())
                .accessibilityLabel("Clear amount")

                digitButton(0)

                Button {
                    submit()
                    keyPressCount += 1
                } label: {
                    Text(isSubmitting ? "saving" : "done")
                        .font(ActualistTypography.control(for: density))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(ActualistTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.45)
                .accessibilityLabel("Move money")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: keyPressCount)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            appendDigit(digit)
            keyPressCount += 1
        } label: {
            Text(String(digit))
                .font(ActualistTypography.keypadDigit(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(BudgetKeypadPressStyle())
        .accessibilityLabel(String(digit))
    }
}

private struct BudgetMoveMoneyDestinationPicker: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Bindable var viewModel: BudgetViewModel

    @State private var searchText = ""
    @State private var isSplitMode = false

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        searchField
                        toBudgetButton
                        destinationGroups
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(viewModel.moveMoneyDraft?.direction == .intoFocusedCategory ? "Move from" : "Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .actualistToolbarGlassButton()
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if isSplitMode {
                            viewModel.finalizeMoveMoneyDestinationSelection()
                            dismiss()
                        } else {
                            isSplitMode = true
                        }
                    } label: {
                        Text(isSplitMode ? "Done" : "Split")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            isSplitMode = viewModel.moveMoneyDraft?.allocations.isEmpty == false
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ActualistTheme.secondaryText)

            TextField("Search Categories", text: $searchText)
                .textInputAutocapitalization(.words)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ActualistTheme.control, in: Capsule())
    }

    @ViewBuilder
    private var toBudgetButton: some View {
        let option = viewModel.toBudgetDestinationOption()
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || option.title.localizedCaseInsensitiveContains(searchText) {
            destinationButton(option)
                .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var destinationGroups: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(viewModel.moveMoneyDestinationGroups(matching: searchText)) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(groupName(group))
                        .font(ActualistTypography.rowLabel(for: density).weight(.bold))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .padding(.horizontal, 22)

                    VStack(spacing: 0) {
                        ForEach(group.options) { option in
                            destinationButton(option)

                            if option.id != group.options.last?.id {
                                Divider()
                                    .overlay(ActualistTheme.separator)
                                    .padding(.leading, 22)
                            }
                        }
                    }
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
    }

    private func destinationButton(_ option: BudgetMoveMoneyDestinationOption) -> some View {
        Button {
            if isSplitMode {
                viewModel.toggleMoveMoneyDestination(option.destination)
            } else {
                viewModel.selectMoveMoneyDestination(option.destination)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Text(optionTitle(option))
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer()

                Text(optionValueText(option))
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(destinationValueForeground(option))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(destinationValueBackground(option), in: Capsule())

                if viewModel.moveMoneyDraft?.destination == option.destination
                    || viewModel.isMoveMoneyDestinationSelected(option.destination) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func destinationValueBackground(_ option: BudgetMoveMoneyDestinationOption) -> Color {
        switch option.destination {
        case .toBudget:
            ActualistTheme.positive
        case .category:
            if option.amount < 0 {
                ActualistTheme.danger
            } else if option.amount == 0 {
                ActualistTheme.neutral
            } else {
                ActualistTheme.positive
            }
        }
    }

    private func destinationValueForeground(_ option: BudgetMoveMoneyDestinationOption) -> Color {
        switch option.destination {
        case .toBudget:
            .black.opacity(0.78)
        case .category:
            option.amount == 0 ? ActualistTheme.secondaryText : .black.opacity(0.78)
        }
    }

    private func groupName(_ group: BudgetMoveMoneyDestinationGroup) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return group.name
        }

        return PrivacyDisplay.name(for: .categoryGroup, seed: group.id)
    }

    private func optionTitle(_ option: BudgetMoveMoneyDestinationOption) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return option.title
        }

        switch option.destination {
        case .toBudget:
            return "To Budget"
        case .category(let id, _):
            return PrivacyDisplay.name(for: .category, seed: id)
        }
    }

    private func optionValueText(_ option: BudgetMoveMoneyDestinationOption) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return option.valueText
        }

        return PrivacyDisplay.money(
            option.amount,
            seed: "move-option-\(option.id)",
            maximumDollars: 900
        )
    }
}

private struct BudgetAssignmentKeypad: View {
    @Environment(\.actualistDensity) private var density

    let canSubmit: Bool
    let canApplyTemplate: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let appendDigit: (Int) -> Void
    let setMode: (BudgetAssignmentInputMode) -> Void
    let applyTemplate: () -> Void
    let moveMoney: () -> Void
    let deleteDigit: () -> Void
    let clearOrCancel: () -> Void
    let cancel: () -> Void
    let submit: () -> Void

    @State private var keyPressCount = 0

    var body: some View {
        VStack(spacing: BudgetKeypadLayout.stackSpacing) {
            HStack(spacing: 12) {
                keypadToolbarButton(title: "Apply Category Template", systemImage: "sparkles", isEnabled: canApplyTemplate) {
                    applyTemplate()
                }
                keypadToolbarButton(title: "Move Money", systemImage: "arrow.right", isEnabled: true) {
                    moveMoney()
                }
                keypadToolbarButton(title: "Details", systemImage: "ellipsis") {}

                Button(action: cancel) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(
                            width: BudgetKeypadLayout.dismissButtonWidth,
                            height: BudgetKeypadLayout.toolbarButtonHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss keypad")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Grid(
                horizontalSpacing: BudgetKeypadLayout.gridHorizontalSpacing,
                verticalSpacing: BudgetKeypadLayout.gridVerticalSpacing
            ) {
                GridRow {
                    digitButton(7)
                    digitButton(8)
                    digitButton(9)
                    modeButton(systemImage: "minus", mode: .subtraction, label: "Subtract from budgeted")
                }

                GridRow {
                    digitButton(4)
                    digitButton(5)
                    digitButton(6)
                    modeButton(systemImage: "plus", mode: .addition, label: "Add to budgeted")
                }

                GridRow {
                    digitButton(1)
                    digitButton(2)
                    digitButton(3)
                    modeButton(systemImage: "equal", mode: .direct, label: "Set budgeted amount")
                }

                GridRow {
                    iconButton(
                        systemImage: "xmark.circle.fill",
                        foreground: ActualistTheme.secondaryText,
                        label: "Clear amount"
                    ) {
                        clearOrCancel()
                    }
                    digitButton(0)
                    iconButton(
                        systemImage: "delete.left",
                        foreground: ActualistTheme.accent,
                        label: "Delete last digit"
                    ) {
                        deleteDigit()
                    }
                    Button {
                        submit()
                        keyPressCount += 1
                    } label: {
                        Text(isSubmitting ? "Saving" : "Done")
                            .font(ActualistTypography.control(for: density))
                            .frame(maxWidth: .infinity)
                            .frame(height: BudgetKeypadLayout.actionHeight)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                    .disabled(!canSubmit)
                    .accessibilityLabel("Save assignment")
                }
            }
        }
        .padding(.horizontal, BudgetKeypadLayout.horizontalPadding)
        .padding(.top, BudgetKeypadLayout.topPadding)
        .padding(.bottom, BudgetKeypadLayout.bottomPadding)
        .background(ActualistTheme.elevatedSurface)
        .disabled(isSubmitting)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: keyPressCount)
    }

    private func keypadToolbarButton(
        title: String,
        systemImage: String,
        isEnabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                Text(title)
                    .font(ActualistTypography.rowLabel(for: density))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.74)
            }
            .foregroundStyle(isEnabled ? ActualistTheme.accent : ActualistTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: BudgetKeypadLayout.toolbarButtonHeight)
            .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            appendDigit(digit)
            keyPressCount += 1
        } label: {
            Text(String(digit))
                .font(ActualistTypography.keypadDigit(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: BudgetKeypadLayout.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(BudgetKeypadPressStyle())
        .accessibilityLabel(String(digit))
    }

    private func modeButton(
        systemImage: String,
        mode: BudgetAssignmentInputMode,
        label: String
    ) -> some View {
        iconButton(systemImage: systemImage, foreground: ActualistTheme.accent, label: label) {
            setMode(mode)
        }
    }

    private func iconButton(
        systemImage: String,
        foreground: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            keyPressCount += 1
        } label: {
            Image(systemName: systemImage)
                .font(ActualistTypography.keypadSymbol(for: density))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: BudgetKeypadLayout.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(BudgetKeypadPressStyle())
        .accessibilityLabel(label)
    }
}
