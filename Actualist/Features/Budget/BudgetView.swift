import SwiftUI

struct BudgetView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = BudgetViewModel()
    @State private var isTransactionEditorPresented = false

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
                TransactionEditorView(prefilledAccount: nil)
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
            HStack(spacing: 10) {
                Text("\(overspendingCount)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(ActualistTheme.danger.opacity(0.8), in: Circle())

                Text("Overspent categories")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button("Cover") {
                }
                .font(.subheadline.weight(.bold))
                .buttonStyle(.glass)
                .tint(ActualistTheme.accent)
            }
            .foregroundStyle(ActualistTheme.primaryText)
            .padding(12)
            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
