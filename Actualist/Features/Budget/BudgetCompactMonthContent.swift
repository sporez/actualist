import SwiftUI

/// One renderer for the interactive month and its temporary, noninteractive slide preview.
struct BudgetCompactMonthContent: View {
    @Environment(AppState.self) private var appState
    let viewModel: BudgetViewModel
    var canChangeVisibility = false
    var action: (Action) -> Void = { _ in }

    enum Action {
        case edit(String, CGRect), toggle(BudgetMonthCategoryGroup), alert(BudgetAlert)
        case categoryNote(BudgetMonthCategory), groupNote(BudgetMonthCategoryGroup)
        case templates(BudgetMonthCategory)
        case categoryVisibility(BudgetMonthCategory, BudgetMonthCategoryGroup)
        case groupVisibility(BudgetMonthCategoryGroup)
        case renameCategory(BudgetMonthCategory), renameGroup(BudgetMonthCategoryGroup)
        case reorder
    }

    var body: some View {
        VStack(spacing: BudgetLayout.sectionSpacing) {
            budgetAlertBanners
            categoryGroups
        }
    }

    private var displayedBudgetMonth: BudgetMonth? {
        BudgetMonthPrivacyProjection.displayMonth(
            viewModel.budgetMonth,
            isEnabled: appState.settings.randomizedDisplayValuesEnabled,
            currency: viewModel.currency
        )
    }

    private var displayedGroups: [BudgetMonthCategoryGroup] {
        BudgetCategoryVisibility.displayedGroups(
            from: displayedBudgetMonth?.categoryGroups ?? [],
            showHidden: appState.settings.showHiddenCategories,
            isTrackingBudget: viewModel.isTrackingBudget
        )
    }

    private var displayedBudgetAlerts: [BudgetAlert] {
        BudgetMonthSummaryPresentation.alerts(
            from: viewModel.budgetAlerts,
            month: displayedBudgetMonth,
            showTotalAssigned: appState.settings.showTotalAssigned,
            includeCarryoverInOverspent: appState.settings.includeCarryoverCategoriesInOverspentAlerts,
            isTrackingBudget: viewModel.isTrackingBudget,
            currency: viewModel.currency
        )
    }

    @ViewBuilder
    private var budgetAlertBanners: some View {
        if let savings = BudgetSavingsPresentation(month: displayedBudgetMonth, currency: viewModel.currency) {
            BudgetSavingsBanner(presentation: savings)
        }
        ForEach(displayedBudgetAlerts) { alert in
            if alert.isActionable {
                Button {
                    action(.alert(alert))
                } label: {
                    budgetAlertLabel(alert)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("budget-alert-\(alert.id)")
            } else {
                budgetAlertLabel(alert)
            }
        }
    }

    private func budgetAlertLabel(_ alert: BudgetAlert) -> some View {
        BudgetAlertBanner(
            alert: alert,
            assignedText: assignedDisplayText(for: alert)
        )
    }

    private func assignedDisplayText(for alert: BudgetAlert) -> String? {
        BudgetMonthSummaryPresentation.assignedValueText(
            for: alert,
            month: displayedBudgetMonth,
            showTotalAssigned: appState.settings.showTotalAssigned,
            currency: viewModel.currency
        )
    }

    private var categoryGroups: some View {
        VStack(spacing: 0) {
            ForEach(displayedGroups) { group in
                BudgetGroupSection(
                    group: group,
                    isExpanded: viewModel.isExpanded(group),
                    isPrivacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
                    assignedDisplay: { category in
                        viewModel.assignedAmountDisplay(for: category, randomized: appState.settings.randomizedDisplayValuesEnabled)
                    },
                    isEditingAssignment: { category in
                        viewModel.isEditingAssignment(for: category)
                    },
                    beginAssignmentEditing: { category, frame in action(.edit(category.id, frame)) },
                    toggle: { action(.toggle(group)) },
                    isTrackingBudget: viewModel.isTrackingBudget,
                    showHidden: appState.settings.showHiddenCategories,
                    hidesCarryoverArrows: appState.settings.hideCarryoverArrows,
                    canChangeVisibility: canChangeVisibility,
                    onOpenCategoryNote: { action(.categoryNote($0)) },
                    onOpenGroupNote: { action(.groupNote(group)) },
                    onOpenTemplates: { action(.templates($0)) },
                    templatesMenuTitle: { category in
                        category.isIncome && !viewModel.isTrackingBudget ? nil
                            : BudgetTemplateDoorKind.kind(hasDefinition: category.hasTemplateDefinition).menuTitle
                    },
                    onToggleCategoryHidden: { action(.categoryVisibility($0, group)) },
                    onToggleGroupHidden: { action(.groupVisibility(group)) },
                    onRenameCategory: { action(.renameCategory($0)) },
                    onRenameGroup: { action(.renameGroup(group)) },
                    onReorder: { action(.reorder) }
                )
            }
        }
    }
}
