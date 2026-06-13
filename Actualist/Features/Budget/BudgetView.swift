import SwiftUI

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @State private var budgetMonth: BudgetMonth?
    @State private var selectedMonth: String?
    @State private var expandedGroups: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let budgetMonth {
                        readyToAssignBanner(budgetMonth)
                        overspendingBanner(budgetMonth)
                        categoryGroups(budgetMonth)
                    } else if isLoading {
                        loadingState
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .actualistToolbarGlassButton()
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .actualistToolbarGlassButton()
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var preferredMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private var navigationTitle: String {
        guard let selectedMonth else {
            return currentMonthTitle
        }

        return title(for: selectedMonth)
    }

    private var currentMonthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: Date())
    }

    private func title(for month: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM"
        guard let date = input.date(from: month) else {
            return month
        }

        let output = DateFormatter()
        output.dateFormat = "MMM yyyy"
        return output.string(from: date)
    }

    private func readyToAssignBanner(_ month: BudgetMonth) -> some View {
        Button {
        } label: {
            HStack {
                Text(month.toBudget.actualMoney.formatted())
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Spacer()
                Text("Ready to Assign")
                    .font(.headline)
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(.black.opacity(0.78))
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(ActualistTheme.positive, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func overspendingBanner(_ month: BudgetMonth) -> some View {
        let overspent = month.categoryGroups
            .flatMap(\.categories)
            .filter { !$0.isIncome && !($0.hidden ?? false) && $0.balance < 0 }

        if !overspent.isEmpty || month.lastMonthOverspent < 0 {
            HStack(spacing: 14) {
                Text("\(max(overspent.count, 1))")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(ActualistTheme.danger.opacity(0.8), in: Circle())

                Text("Overspent categories")
                    .font(.headline)

                Spacer()

                Button("Cover") {
                }
                .font(.headline.weight(.bold))
                .buttonStyle(.glass)
                .tint(ActualistTheme.accent)
            }
            .foregroundStyle(ActualistTheme.primaryText)
            .padding(16)
            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private func categoryGroups(_ month: BudgetMonth) -> some View {
        LazyVStack(spacing: 0, pinnedViews: []) {
            ForEach(month.categoryGroups.filter { !$0.isIncome }) { group in
                BudgetGroupSection(
                    group: group,
                    isExpanded: expandedGroups.contains(group.id),
                    toggle: {
                        withAnimation(.smooth(duration: 0.2)) {
                            if expandedGroups.contains(group.id) {
                                expandedGroups.remove(group.id)
                            } else {
                                expandedGroups.insert(group.id)
                            }
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
                Text(errorMessage ?? "Budget data will appear after Actualist connects.")
                    .font(.headline)
                    .foregroundStyle(ActualistTheme.primaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        await appState.loadBudgets()

        guard let budgetID = appState.settings.selectedBudgetID,
              let client = appState.makeClient() else {
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let availableMonths = try await client.budgetMonths(budgetID: budgetID)
            let monthID = availableMonths.contains(preferredMonth) ? preferredMonth : (availableMonths.last ?? preferredMonth)
            let month = try await client.budgetMonth(budgetID: budgetID, month: monthID)
            budgetMonth = month
            selectedMonth = month.month
            expandedGroups = Set(month.categoryGroups.prefix(3).map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct BudgetGroupSection: View {
    let group: BudgetMonthCategoryGroup
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .font(.title3.weight(.bold))
                        .frame(width: 28)

                    Text(group.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Assigned")
                            .font(.callout)
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(group.budgeted.actualMoney.formatted())
                            .font(.headline.weight(.bold))
                    }

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Available")
                            .font(.callout)
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(group.balance.actualMoney.formatted())
                            .font(.headline.weight(.bold))
                    }
                }
                .foregroundStyle(ActualistTheme.primaryText)
                .padding(.vertical, 18)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(group.categories.filter { !($0.hidden ?? false) }) { category in
                    BudgetCategoryRow(category: category)
                }
            }
        }
    }
}

struct BudgetCategoryRow: View {
    let category: BudgetMonthCategory

    var body: some View {
        HStack(spacing: 8) {
            emojiSlot

            Text(nameParts.name)
                .font(.body)
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(category.budgeted.actualMoney.formatted())
                .font(.headline.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 100, alignment: .trailing)

            Text(category.balance.actualMoney.formatted())
                .font(.subheadline.weight(.bold))
                .foregroundStyle(availableForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 108)
                .background(availableBackground, in: Capsule())
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 4)
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
                .font(.actualistEmoji(size: 22))
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: 30, height: 30)
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
