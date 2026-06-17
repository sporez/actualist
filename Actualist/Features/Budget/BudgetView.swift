import SwiftUI

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = BudgetViewModel()
    @State private var isTransactionEditorPresented = false
    @State private var isMonthPickerPresented = false
    @State private var assignmentKeypadHeight: CGFloat = 0
    @State private var assignmentScrollTask: Task<Void, Never>?
    @State private var assignmentEditingCategoryFrame: CGRect = .zero
    @State private var assignmentKeypadTopY: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: BudgetLayout.sectionSpacing) {
                        if viewModel.budgetMonth != nil {
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
                            isSubmitting: viewModel.isSubmittingAssignment,
                            errorMessage: viewModel.activeAssignmentErrorMessage,
                            appendDigit: { viewModel.appendAssignmentDigit($0) },
                            setMode: { viewModel.setAssignmentInputMode($0) },
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
                                selectedMonth: viewModel.selectedMonth
                            ) { month in
                                isMonthPickerPresented = false
                                Task { await viewModel.selectMonth(month, using: appState) }
                            }
                            .presentationCompactAdaptation(.popover)
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await viewModel.load(using: appState) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
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

    private var scrollBottomPadding: CGFloat {
        guard viewModel.isAssignmentKeypadPresented else {
            return 28
        }

        return max(assignmentKeypadHeight + BudgetLayout.assignmentScrollBottomClearance, 360)
    }

    private var budgetAlertBanners: some View {
        ForEach(viewModel.budgetAlerts) { alert in
            Button {
            } label: {
                HStack(spacing: 10) {
                    if let valueText = alert.valueText {
                        Text(valueText)
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

                    Image(systemName: "chevron.right")
                        .font(.body.weight(.bold))
                }
                .foregroundStyle(alert.foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    alert.backgroundView
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var categoryGroups: some View {
        LazyVStack(spacing: 0, pinnedViews: []) {
            ForEach(viewModel.visibleGroups) { group in
                BudgetGroupSection(
                    group: group,
                    isExpanded: viewModel.isExpanded(group),
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

private extension BudgetAlert {
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

private struct BudgetMonthPicker: View {
    @Environment(\.actualistDensity) private var density

    let availableMonths: [String]
    let selectedMonth: String?
    let onSelect: (String) -> Void

    @State private var displayedYear: Int

    init(
        availableMonths: [String],
        selectedMonth: String?,
        onSelect: @escaping (String) -> Void
    ) {
        self.availableMonths = availableMonths
        self.selectedMonth = selectedMonth
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
                    .disabled(!availableMonthSet.contains(monthID))
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
        availableYears.contains(where: { $0 < displayedYear })
    }

    private var hasNextYear: Bool {
        availableYears.contains(where: { $0 > displayedYear })
    }

    private func monthTextColor(_ monthID: String) -> Color {
        if monthID == selectedMonth {
            return ActualistTheme.primaryText
        }

        return availableMonthSet.contains(monthID) ? ActualistTheme.primaryText : ActualistTheme.secondaryText.opacity(0.36)
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
    static let actionHeight: CGFloat = 54
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

struct BudgetGroupSection: View {
    @Environment(\.actualistDensity) private var density

    let group: BudgetMonthCategoryGroup
    let isExpanded: Bool
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

                    Text(group.name)
                        .font(ActualistTypography.sectionTitle(for: density))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Assigned")
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(group.budgeted.actualMoney.formatted())
                            .font(ActualistTypography.rowValue(for: density))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(width: BudgetLayout.assignedWidth, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Available")
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(group.balance.actualMoney.formatted())
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
                    ForEach(group.visibleCategories) { category in
                        BudgetCategoryRow(
                            category: category,
                            assignedDisplay: assignedDisplay(category),
                            isEditing: isEditingAssignment(category),
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
}

struct BudgetCategoryRow: View {
    @Environment(\.actualistDensity) private var density

    let category: BudgetMonthCategory
    let assignedDisplay: BudgetAssignedAmountDisplay
    let isEditing: Bool
    let beginAssignmentEditing: (CGRect) -> Void

    @State private var globalFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: BudgetLayout.rowSpacing) {
            emojiSlot

            Text(nameParts.name)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                beginAssignmentEditing(globalFrame)
            } label: {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(assignedDisplay.primaryText)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(assignedDisplay.isEditing)

            Text(category.balance.actualMoney.formatted())
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
            Rectangle()
                .fill(ActualistTheme.separator)
                .frame(height: 1)
                .padding(.leading, BudgetLayout.emojiWidth + BudgetLayout.rowSpacing)
        }
    }

    @ViewBuilder
    private var emojiSlot: some View {
        if let emoji = nameParts.emoji {
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
            return Color.gray.opacity(0.45)
        }
        return ActualistTheme.positive
    }

    private var availableForeground: Color {
        category.balance == 0 ? ActualistTheme.secondaryText : .black.opacity(0.78)
    }

    private var nameParts: CategoryNameParts {
        category.name.actualistCategoryNameParts
    }
}

private struct BudgetAssignmentKeypad: View {
    @Environment(\.actualistDensity) private var density

    let canSubmit: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let appendDigit: (Int) -> Void
    let setMode: (BudgetAssignmentInputMode) -> Void
    let deleteDigit: () -> Void
    let clearOrCancel: () -> Void
    let cancel: () -> Void
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()

                Button(action: cancel) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(width: 52, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityLabel("Dismiss keypad")
            }
            .padding(.bottom, -6)

            HStack(spacing: 12) {
                keypadToolbarButton(title: "Auto-Assign", systemImage: "bolt.fill") {}
                keypadToolbarButton(title: "Move Money", systemImage: "arrow.right") {}
                keypadToolbarButton(title: "Details", systemImage: "ellipsis") {}
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                GridRow {
                    digitButton(7)
                    digitButton(8)
                    digitButton(9)
                    modeButton(systemImage: "minus", mode: .subtraction)
                }

                GridRow {
                    digitButton(4)
                    digitButton(5)
                    digitButton(6)
                    modeButton(systemImage: "plus", mode: .addition)
                }

                GridRow {
                    digitButton(1)
                    digitButton(2)
                    digitButton(3)
                    modeButton(systemImage: "equal", mode: .direct)
                }

                GridRow {
                    iconButton(systemImage: "xmark.circle.fill", foreground: ActualistTheme.secondaryText) {
                        clearOrCancel()
                    }
                    digitButton(0)
                    iconButton(systemImage: "delete.left", foreground: ActualistTheme.accent) {
                        deleteDigit()
                    }
                    Button(action: submit) {
                        Text(isSubmitting ? "saving" : "done")
                            .font(ActualistTypography.control(for: density))
                            .frame(maxWidth: .infinity)
                            .frame(height: BudgetKeypadLayout.actionHeight)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                    .disabled(!canSubmit || isSubmitting)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .background(ActualistTheme.elevatedSurface)
    }

    private func keypadToolbarButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                Text(title)
                    .font(ActualistTypography.rowLabel(for: density))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(ActualistTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(true)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            appendDigit(digit)
        } label: {
            Text(String(digit))
                .font(.system(size: 32, weight: .regular, design: .rounded))
                .foregroundStyle(ActualistTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: BudgetKeypadLayout.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    private func modeButton(
        systemImage: String,
        mode: BudgetAssignmentInputMode
    ) -> some View {
        iconButton(systemImage: systemImage, foreground: ActualistTheme.accent) {
            setMode(mode)
        }
    }

    private func iconButton(
        systemImage: String,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: BudgetKeypadLayout.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }
}
