import SwiftUI

struct BudgetGroupSection: View {
    @Environment(\.actualistDensity) private var density
    @Environment(\.budgetCurrency) private var currency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let group: BudgetMonthCategoryGroup
    let isExpanded: Bool
    let isPrivacyModeEnabled: Bool
    let assignedDisplay: (BudgetMonthCategory) -> BudgetAssignedAmountDisplay
    let isEditingAssignment: (BudgetMonthCategory) -> Bool
    let beginAssignmentEditing: (BudgetMonthCategory, CGRect) -> Void
    let toggle: () -> Void
    var isTrackingBudget = false
    var showHidden = false
    var hidesCarryoverArrows = false
    var canChangeVisibility = true
    var onOpenCategoryNote: (BudgetMonthCategory) -> Void = { _ in }
    var onOpenGroupNote: () -> Void = {}
    var onOpenTemplates: (BudgetMonthCategory) -> Void = { _ in }
    var templatesMenuTitle: (BudgetMonthCategory) -> String? = { _ in nil }
    var onToggleCategoryHidden: (BudgetMonthCategory) -> Void = { _ in }
    var onToggleGroupHidden: () -> Void = {}
    var onRenameCategory: (BudgetMonthCategory) -> Void = { _ in }
    var onRenameGroup: () -> Void = {}
    var onReorder: () -> Void = {}

    private var displayedCategories: [BudgetMonthCategory] {
        BudgetCategoryVisibility.displayedCategories(in: group, showHidden: showHidden)
    }

    private var isGroupHidden: Bool {
        BudgetCategoryVisibility.isHidden(group.hidden)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                groupRowLabel
                .foregroundStyle(ActualistTheme.primaryText)
                .padding(.vertical, 12)
                .padding(.horizontal, BudgetLayout.rowHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(BudgetRowButtonStyle())
            .accessibilityIdentifier("budget-group-\(group.id)")
            .opacity(isGroupHidden ? BudgetLayout.hiddenCategoryOpacity : 1)
            .contextMenu {
                Button {
                    onOpenGroupNote()
                } label: {
                    Label("Notes", systemImage: "note.text")
                }

                if !group.isIncome {
                    Button {
                        onToggleGroupHidden()
                    } label: {
                        Label(isGroupHidden ? "Show" : "Hide", systemImage: isGroupHidden ? "eye" : "eye.slash")
                    }
                    .disabled(!canChangeVisibility)
                }

                if isTrackingBudget || !group.isIncome {
                    Divider()

                    Button {
                        onRenameGroup()
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("budget-group-rename-\(group.id)")

                    Button {
                        onReorder()
                    } label: {
                        Label("Reorder", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityIdentifier("budget-group-reorder-\(group.id)")
                }
            }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(displayedCategories.enumerated()), id: \.element.id) { index, category in
                        BudgetCategoryRow(
                            category: category,
                            assignedDisplay: assignedDisplay(category),
                            isEditing: isEditingAssignment(category),
                            isPrivacyModeEnabled: isPrivacyModeEnabled,
                            showsBottomSeparator: index < displayedCategories.count - 1,
                            isTrackingBudget: isTrackingBudget,
                            isDimmed: BudgetCategoryVisibility.isEffectivelyHidden(
                                category: category,
                                group: group
                            ),
                            hidesCarryoverArrows: hidesCarryoverArrows,
                            canChangeVisibility: canChangeVisibility && !isGroupHidden,
                            beginAssignmentEditing: { categoryFrame in
                                beginAssignmentEditing(category, categoryFrame)
                            },
                            onOpenNote: {
                                onOpenCategoryNote(category)
                            },
                            templatesMenuTitle: templatesMenuTitle(category),
                            onOpenTemplates: {
                                onOpenTemplates(category)
                            },
                            onToggleHidden: {
                                onToggleCategoryHidden(category)
                            },
                            canManageLifecycle: isTrackingBudget || !category.isIncome,
                            onRename: { onRenameCategory(category) },
                            onReorder: onReorder
                        )
                        .id(BudgetScrollTarget.category(category.id))
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
        currency.formatted(group.budgeted)
    }

    private var semantics: BudgetModePresentation {
        .init(isTracking: isTrackingBudget, isIncome: group.isIncome)
    }

    private var groupSecondValue: BudgetSecondValuePresentation {
        semantics.secondValue(balance: group.balance, activity: group.spent, currency: currency)
    }

    @ViewBuilder
    private var groupRowLabel: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                groupHeading
                VStack(spacing: 6) {
                    groupTotalRow(label: semantics.budgetedLabel, value: groupBudgetedText)
                    groupTotalRow(label: groupSecondValue.label, value: groupSecondValue.text)
                }
            }
        } else {
            HStack(alignment: .center, spacing: BudgetLayout.rowSpacing) {
                groupHeading
                Spacer()
                groupTotal(label: semantics.budgetedLabel, value: groupBudgetedText, width: BudgetLayout.assignedWidth)
                groupTotal(label: groupSecondValue.label, value: groupSecondValue.text, width: BudgetLayout.availableWidth)
            }
        }
    }

    private var groupHeading: some View {
        HStack(spacing: BudgetLayout.rowSpacing) {
            Image(systemName: "chevron.down")
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .font(.body.weight(.bold))
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : BudgetLayout.chevronWidth)

            HStack(spacing: 6) {
                Text(groupName)
                    .font(ActualistTypography.sectionTitle(for: density))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.82)
                    .layoutPriority(1)

                if group.hasUserNote {
                    Image(systemName: "note.text")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .accessibilityHidden(true)
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupTotalRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(ActualistTypography.rowValue(for: density))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func groupTotal(label: String, value: String, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(label)
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(value)
                .font(ActualistTypography.rowValue(for: density))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: width, alignment: .trailing)
    }
}

struct BudgetCategoryRow: View {
    @Environment(\.actualistDensity) private var density
    @Environment(\.budgetCurrency) private var currency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let category: BudgetMonthCategory
    let assignedDisplay: BudgetAssignedAmountDisplay
    let isEditing: Bool
    let isPrivacyModeEnabled: Bool
    let showsBottomSeparator: Bool
    var isTrackingBudget = false
    var isDimmed = false
    var hidesCarryoverArrows = false
    var canChangeVisibility = false
    let beginAssignmentEditing: (CGRect) -> Void
    var onOpenNote: () -> Void = {}
    var templatesMenuTitle: String? = nil
    var onOpenTemplates: () -> Void = {}
    var onToggleHidden: () -> Void = {}
    var canManageLifecycle = false
    var onRename: () -> Void = {}
    var onReorder: () -> Void = {}

    @State private var measuredFrame = BudgetCategoryRowFrame()

    var body: some View {
        Button {
            if !assignedDisplay.isEditing {
                beginAssignmentEditing(measuredFrame.value)
            }
        } label: {
            categoryRowLabel
            .padding(.vertical, 10)
            .padding(.horizontal, BudgetLayout.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(BudgetRowButtonStyle())
        .accessibilityIdentifier("budget-category-\(category.id)")
        .opacity(isDimmed ? BudgetLayout.hiddenCategoryOpacity : 1)
        .contextMenu {
            Button {
                onOpenNote()
            } label: {
                Label("Notes", systemImage: "note.text")
            }

            if let templatesMenuTitle {
                Button {
                    onOpenTemplates()
                } label: {
                    Label(templatesMenuTitle, systemImage: "sparkles")
                }
            }

            if canChangeVisibility {
                Button {
                    onToggleHidden()
                } label: {
                    Label(
                        BudgetCategoryVisibility.isHidden(category.hidden) ? "Show" : "Hide",
                        systemImage: BudgetCategoryVisibility.isHidden(category.hidden) ? "eye" : "eye.slash"
                    )
                }
            }

            if canManageLifecycle {
                Divider()

                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier("budget-category-rename-\(category.id)")

                Button {
                    onReorder()
                } label: {
                    Label("Reorder", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("budget-category-reorder-\(category.id)")
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            measuredFrame.value = frame
        }
        .background(isEditing ? ActualistTheme.elevatedSurface : Color.clear, in: Rectangle())
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
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.86)
                .layoutPriority(1)

            if category.hasUserNote {
                Image(systemName: "note.text")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var semantics: BudgetModePresentation {
        .init(isTracking: isTrackingBudget, isIncome: category.isIncome)
    }

    private var secondValue: BudgetSecondValuePresentation {
        semantics.secondValue(balance: category.balance, activity: category.spent,
            carryover: category.carryover, currency: currency)
    }

    private var availablePill: some View {
        BudgetAmountPill(value: secondValue, hidesCarryoverArrow: hidesCarryoverArrows,
            horizontalPadding: BudgetLayout.availablePillHorizontalPadding,
            rolloverOffset: BudgetLayout.rolloverBadgeOffset)
            .frame(
                width: dynamicTypeSize.isAccessibilitySize ? nil : BudgetLayout.availableWidth,
                alignment: .trailing
            )
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
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

    @ViewBuilder
    private var categoryRowLabel: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                categoryLabel
                VStack(spacing: 6) {
                    HStack {
                        Text(semantics.budgetedLabel)
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Spacer(minLength: 12)
                        assignedAmount
                    }
                    HStack {
                        Text(secondValue.label)
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Spacer(minLength: 12)
                        availablePill
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: BudgetLayout.rowSpacing) {
                categoryLabel
                assignedAmount.frame(width: BudgetLayout.assignedWidth, alignment: .trailing)
                availablePill
            }
        }
    }

    private var assignedAmount: some View {
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
    }
}

/// PlainButtonStyle can retain its dimmed press rendering when an edge drag
/// disables a row mid-touch. Keep row colors stable; Button still owns activation
/// and accessibility, and hidden-category opacity remains explicit on the row.
private struct BudgetRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Hit-time geometry is not render state. Publishing every scroll-frame measurement redraws all rows.
private final class BudgetCategoryRowFrame {
    var value: CGRect = .zero
}
