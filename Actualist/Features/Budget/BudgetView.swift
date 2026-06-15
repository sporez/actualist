import SwiftUI

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = BudgetViewModel()
    @State private var isTransactionEditorPresented = false
    @State private var isMonthPickerPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: BudgetLayout.sectionSpacing) {
                    if let budgetMonth = viewModel.budgetMonth {
                        readyToAssignBanner(budgetMonth)
                        overspendingBanner
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

    private func readyToAssignBanner(_ month: BudgetMonth) -> some View {
        Button {
        } label: {
            HStack {
                Text(month.toBudget.actualMoney.formatted())
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Text("To Budget")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.bold))
            }
            .foregroundStyle(.black.opacity(0.78))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ActualistTheme.positive, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var overspendingBanner: some View {
        if let overspendingCount = viewModel.overspendingAlertCount {
            Button {
            } label: {
                HStack(spacing: 10) {
                    Text("\(overspendingCount)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(ActualistTheme.danger.opacity(0.8), in: Circle())

                    Text("Overspent categories")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text("Cover")
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.body.weight(.bold))
                }
                .foregroundStyle(ActualistTheme.primaryText)
                .padding(12)
                .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                    .font(.largeTitle)
                    .foregroundStyle(ActualistTheme.accent)
                Text(viewModel.errorMessage ?? "Budget data will appear after Actualist connects.")
                    .font(.headline)
                    .foregroundStyle(ActualistTheme.primaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BudgetMonthPicker: View {
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
                        .font(.title3.weight(.bold))
                }
                .disabled(!hasPreviousYear)

                Spacer()

                Text(String(displayedYear))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer()

                Button {
                    displayedYear += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.bold))
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
                            .font(.title3.weight(monthID == selectedMonth ? .bold : .regular))
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
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Assigned")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(group.budgeted.actualMoney.formatted())
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(width: BudgetLayout.assignedWidth, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Available")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(group.balance.actualMoney.formatted())
                            .font(.subheadline.weight(.bold))
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
    let category: BudgetMonthCategory

    var body: some View {
        HStack(spacing: BudgetLayout.rowSpacing) {
            emojiSlot

            Text(nameParts.name)
                .font(.callout)
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(category.budgeted.actualMoney.formatted())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: BudgetLayout.assignedWidth, alignment: .trailing)

            Text(category.balance.actualMoney.formatted())
                .font(.subheadline.weight(.bold))
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
