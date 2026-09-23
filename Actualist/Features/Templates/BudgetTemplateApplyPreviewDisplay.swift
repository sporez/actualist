import Foundation

/// Prepared Apply confirmation copy. Views render this; they do not format
/// money or decide To Budget vs Total Saved.
struct BudgetTemplateApplyPreviewDisplay: Equatable, Sendable {
    struct Category: Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var currentText: String
        var proposedText: String
        var metricTitle: String
        var metricBeforeText: String
        var metricAfterText: String
        var statusText: String
        var shortfallText: String?
        var targetDetailText: String?
        var contributions: [Contribution]
    }

    struct Contribution: Equatable, Identifiable, Sendable {
        var id: Int
        var title: String
        var amountText: String
    }

    var fundingRequiredText: String
    var assignedText: String
    var releasedTitle: String
    var releasedText: String?
    var stillNeededText: String?
    var leftoverTitle: String
    var leftoverBeforeText: String
    var leftoverAfterText: String
    var changeCountText: String
    var hasNonMoneyUpdates: Bool
    var noOpExplanation: String?
    var warningText: String?
    var categories: [Category]

    static func leftoverTitle(isTrackingBudget: Bool) -> String {
        isTrackingBudget ? "Total Saved" : "To Budget"
    }

    static func changeCountText(_ count: Int) -> String {
        switch count {
        case 0:
            "None"
        case 1:
            "1 category"
        default:
            "\(count) categories"
        }
    }

    static func make(
        preview: BudgetTemplateApplyPreview,
        randomized: Bool
    ) -> BudgetTemplateApplyPreviewDisplay {
        let currency = preview.currency
        let isPrivate = randomized
        let hasGoalOnlyUpdates = preview.categories.contains { $0.isGoalOnlyUpdate }
        let noOpExplanation: String? = {
            guard preview.assigned == 0, preview.released == 0, !hasGoalOnlyUpdates else { return nil }
            if preview.stillNeeded > 0 { return "No funds are available for the remaining template targets." }
            return preview.hasEligibleTemplates
                ? "Assignments already match their template targets."
                : "No eligible templates were found for this month."
        }()
        let availableBefore = preview.availableBefore
        return BudgetTemplateApplyPreviewDisplay(
            fundingRequiredText: money(
                preview.fundingRequired,
                currency: currency,
                randomized: isPrivate
            ),
            assignedText: money(
                preview.assigned,
                currency: currency,
                randomized: randomized
            ),
            releasedTitle: preview.isTrackingBudget ? "Reduced" : "Released",
            releasedText: preview.released > 0 ? money(
                preview.released,
                currency: currency,
                randomized: isPrivate
            ) : nil,
            stillNeededText: preview.stillNeeded > 0 ? money(
                preview.stillNeeded,
                currency: currency,
                randomized: isPrivate
            ) : nil,
            leftoverTitle: leftoverTitle(isTrackingBudget: preview.isTrackingBudget),
            leftoverBeforeText: money(
                availableBefore,
                currency: currency,
                randomized: isPrivate
            ),
            leftoverAfterText: money(
                preview.availableAfter,
                currency: currency,
                randomized: isPrivate
            ),
            changeCountText: changeCountText(preview.categories.count),
            hasNonMoneyUpdates: hasGoalOnlyUpdates,
            noOpExplanation: noOpExplanation,
            warningText: preview.availableAfter < 0 ? "Over budget after Apply." : nil,
            categories: preview.categories.map { category in
                Category(
                    id: category.categoryID,
                    name: name(category, randomized: randomized),
                    currentText: money(
                        category.current,
                        currency: currency,
                        randomized: randomized
                    ),
                    proposedText: money(
                        category.proposed,
                        currency: currency,
                        randomized: randomized
                    ),
                    metricTitle: category.metric.title,
                    metricBeforeText: money(
                        category.metric.before,
                        currency: currency,
                        randomized: isPrivate
                    ),
                    metricAfterText: money(
                        category.metric.after,
                        currency: currency,
                        randomized: isPrivate
                    ),
                    statusText: status(for: category),
                    shortfallText: category.shortfall > 0 ? money(
                        category.shortfall,
                        currency: currency,
                        randomized: isPrivate
                    ) : nil,
                    targetDetailText: targetDetailText(for: category, currency: currency, randomized: isPrivate),
                    contributions: contributions(
                        category,
                        currency: currency,
                        randomized: randomized
                    )
                )
            }
        )
    }

    private static func name(
        _ category: BudgetTemplateApplyPreview.Category,
        randomized: Bool
    ) -> String {
        randomized
            ? PrivacyDisplay.name(for: .category, seed: "template-apply-category-\(category.categoryID)")
            : category.name.actualistCategoryNameParts.name
    }

    private static func status(for category: BudgetTemplateApplyPreview.Category) -> String {
        if category.evaluatedDemand <= 0 {
            return category.isGoalOnlyUpdate ? "Goal update" : (category.current == category.proposed ? "No assignment change" : "Updated")
        }
        if category.shortfall == 0 { return "Fully funded" }
        return category.current == category.proposed ? "Unfunded" : "Partially funded"
    }

    private static func targetDetailText(
        for category: BudgetTemplateApplyPreview.Category,
        currency: BudgetCurrency,
        randomized: Bool
    ) -> String? {
        if category.isGoalOnlyUpdate {
            guard let goalAfter = category.goalAfter else { return "Goal target removed" }
            let after = money(goalAfter, currency: currency, randomized: randomized)
            guard let goalBefore = category.goalBefore else { return "Goal target \(after)" }
            return "Goal target \(money(goalBefore, currency: currency, randomized: randomized)) → \(after)"
        }
        guard category.shortfall > 0, let target = category.goalAfter else { return nil }
        return "Template target \(money(target, currency: currency, randomized: randomized))"
    }

    private static func contributions(
        _ category: BudgetTemplateApplyPreview.Category,
        currency: BudgetCurrency,
        randomized: Bool
    ) -> [Contribution] {
        guard category.perTemplate.count > 1 else {
            return []
        }
        let hasAlignedDrafts = category.drafts.count == category.perTemplate.count
        return category.perTemplate.enumerated().compactMap { index, amount in
            if hasAlignedDrafts,
               category.drafts.indices.contains(index),
               !category.drafts[index].showsContribution {
                return nil
            }
            return Contribution(
                id: index,
                title: contributionTitle(
                    category,
                    index: index,
                    currency: currency,
                    randomized: randomized
                ),
                amountText: randomized ? "Hidden" : BudgetTemplateAmountInput.contributionText(
                    minorUnits: amount,
                    currency: currency,
                    randomized: false,
                    seed: "template-apply-\(category.categoryID)-\(index)"
                )
            )
        }
    }

    private static func contributionTitle(
        _ category: BudgetTemplateApplyPreview.Category,
        index: Int,
        currency: BudgetCurrency,
        randomized: Bool
    ) -> String {
        if randomized { return category.drafts.indices.contains(index) ? category.drafts[index].kind.title : "Template \(index + 1)" }
        if category.drafts.count == category.perTemplate.count,
           category.drafts.indices.contains(index) {
            let draft = category.drafts[index]
            if case .average = draft.kind {
                return BudgetTemplateSummary.label(
                    draft,
                    currency: currency,
                    randomized: randomized,
                    seed: "template-contribution-\(index)"
                ) ?? draft.kind.title
            }
            if case .schedule = draft.kind {
                return BudgetTemplateSummary.label(
                    draft,
                    currency: currency,
                    randomized: randomized,
                    seed: "template-contribution-\(index)"
                ) ?? draft.kind.title
            }
            return draft.kind.title
        }
        return "Template \(index + 1)"
    }

    private static func money(
        _ amount: Int,
        currency: BudgetCurrency,
        randomized: Bool
    ) -> String {
        if randomized {
            // Sample Values must not expose independently randomized arithmetic.
            return "Hidden"
        }
        return currency.formatted(amount)
    }
}
