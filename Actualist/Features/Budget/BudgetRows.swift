import SwiftUI

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
                categoryLabel

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

                availablePill
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
                    .padding(.leading, BudgetLayout.rowHorizontalPadding)
            }
        }
    }

    @ViewBuilder
    private var categoryLabel: some View {
        HStack(spacing: BudgetLayout.emojiNameSpacing) {
            if !isPrivacyModeEnabled, let emoji = nameParts.emoji {
                Text(verbatim: emoji)
                    .font(.actualistEmoji(size: BudgetLayout.emojiSize))
                    .accessibilityHidden(true)
            }

            Text(categoryName)
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if category.balance < 0 {
            return ActualistTheme.dangerForeground
        }
        if category.balance == 0 {
            return ActualistTheme.neutralForeground
        }
        return ActualistTheme.positiveForeground
    }

    private var availablePill: some View {
        Text(availableText)
            .font(ActualistTypography.rowValue(for: density))
            .foregroundStyle(availableForeground)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.leading, BudgetLayout.availablePillHorizontalPadding)
            .padding(
                .trailing,
                BudgetLayout.availablePillHorizontalPadding
                    + (category.carryover ? BudgetLayout.rolloverIndicatorReservedWidth : 0)
            )
            .padding(.vertical, 5)
            .background(availableBackground, in: Capsule())
            .overlay(alignment: .topTrailing) {
                if category.carryover {
                    Image(systemName: "arrow.right")
                        .font(.system(size: BudgetLayout.rolloverIndicatorSize, weight: .black))
                        .foregroundStyle(availableForeground.opacity(0.82))
                        .padding(.top, BudgetLayout.rolloverIndicatorTopPadding)
                        .padding(.trailing, BudgetLayout.rolloverIndicatorTrailingPadding)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: BudgetLayout.availableWidth, alignment: .trailing)
            .accessibilityLabel(
                category.carryover
                    ? "\(availableText), rollover enabled"
                    : availableText
            )
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

