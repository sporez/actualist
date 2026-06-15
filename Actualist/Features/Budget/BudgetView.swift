import SwiftUI

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = BudgetViewModel()
    @State private var isTransactionEditorPresented = false
    @State private var isMonthPickerPresented = false

    var body: some View {
        NavigationStack {
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
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle(viewModel.navigationTitle)
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
            .sheet(isPresented: $isTransactionEditorPresented) {
                TransactionEditorView(prefilledAccount: nil) {
                    Task { await viewModel.refreshSelectedMonth(using: appState) }
                }
                    .environment(appState)
            }
        }
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
                    toggle: {
                        withAnimation(.smooth(duration: 0.2)) {
                            viewModel.toggle(group)
                        }
                    }
                )
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
    static let chevronWidth: CGFloat = 24
    static let emojiSize: CGFloat = 20
    static let emojiWidth: CGFloat = 26
    static let assignedWidth: CGFloat = 96
    static let availableWidth: CGFloat = 112
}

struct BudgetGroupSection: View {
    @Environment(\.actualistDensity) private var density

    let group: BudgetMonthCategoryGroup
    let isExpanded: Bool
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
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(group.visibleCategories) { category in
                    BudgetCategoryRow(category: category)
                }
            }
        }
    }
}

struct BudgetCategoryRow: View {
    @Environment(\.actualistDensity) private var density

    let category: BudgetMonthCategory

    var body: some View {
        HStack(spacing: BudgetLayout.rowSpacing) {
            emojiSlot

            Text(nameParts.name)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(category.budgeted.actualMoney.formatted())
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: BudgetLayout.assignedWidth, alignment: .trailing)

            Text(category.balance.actualMoney.formatted())
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle(availableForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: BudgetLayout.availableWidth)
                .background(availableBackground, in: Capsule())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ActualistTheme.separator)
                .frame(height: 1)
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
