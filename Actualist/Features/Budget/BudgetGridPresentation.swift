import Foundation

struct BudgetGridPresentation {
    struct Month: Identifiable {
        let id: String
        let title: String
        let snapshot: LoadedBudgetMonth?
        let display: BudgetMonth?
        let alerts: [BudgetAlert]
        let toBudgetText: String
        let assignedText: String?
        let error: String?

        var currency: BudgetCurrency { snapshot?.currency ?? .usd }
        var toBudgetAmount: Int { display?.toBudget ?? 0 }
    }

    struct Group: Identifiable {
        let source: BudgetMonthCategoryGroup
        let title: String
        let categories: [Category]
        var id: String { source.id }
    }

    struct Category: Identifiable {
        let source: BudgetMonthCategory
        let title: String
        let emoji: String?
        var id: String { source.id }
    }

    let months: [Month]
    let groups: [Group]
    let rangeTitle: String

    init(
        visibleMonths: [String],
        snapshots: [String: LoadedBudgetMonth],
        errors: [String: String] = [:],
        privacyEnabled: Bool,
        showHidden: Bool,
        showTotalAssigned: Bool,
        includeCarryover: Bool
    ) {
        months = visibleMonths.map { id in
            let snapshot = snapshots[id]
            let currency = snapshot?.currency ?? .usd
            let display = BudgetMonthPrivacyProjection.displayMonth(
                snapshot?.month, isEnabled: privacyEnabled, currency: currency
            )
            let alerts = BudgetMonthSummaryPresentation.alerts(
                from: snapshot?.alerts.compactMap { BudgetAlert(alert: $0, currency: currency) } ?? [],
                month: display,
                showTotalAssigned: showTotalAssigned,
                includeCarryoverInOverspent: includeCarryover,
                isTrackingBudget: snapshot?.isTrackingBudget ?? false,
                currency: currency
            ).filter { $0.kind != .toBudget }
            return Month(
                id: id,
                title: BudgetMonthNavigationPresentation.title(for: id),
                snapshot: snapshot,
                display: display,
                alerts: alerts,
                toBudgetText: display.map { currency.formatted($0.toBudget) } ?? "—",
                assignedText: showTotalAssigned ? display.map { currency.formatted($0.totalBudgeted) } : nil,
                error: errors[id]
            )
        }
        let hierarchy = months.compactMap(\.snapshot).first?.month.categoryGroups ?? []
        groups = BudgetCategoryVisibility.displayedGroups(from: hierarchy, showHidden: showHidden).map { group in
            Group(
                source: group,
                title: privacyEnabled ? PrivacyDisplay.name(for: .categoryGroup, seed: group.id) : group.name,
                categories: BudgetCategoryVisibility.displayedCategories(in: group, showHidden: showHidden).map { category in
                    Category(
                        source: category,
                        title: privacyEnabled ? PrivacyDisplay.name(for: .category, seed: category.id) : category.name.actualistCategoryNameParts.name,
                        emoji: privacyEnabled ? nil : category.name.actualistCategoryNameParts.emoji
                    )
                }
            )
        }
        let titles = months.map(\.title)
        if let first = titles.first, let last = titles.last, titles.count > 1 {
            rangeTitle = "\(first) – \(last)"
        } else {
            rangeTitle = titles.first ?? "Budget"
        }
    }

    func category(_ id: String, month: Month) -> BudgetMonthCategory? {
        month.display?.categoryGroups.flatMap(\.categories).first { $0.id == id }
    }

    func group(_ id: String, month: Month) -> BudgetMonthCategoryGroup? {
        month.display?.categoryGroups.first { $0.id == id }
    }
}
