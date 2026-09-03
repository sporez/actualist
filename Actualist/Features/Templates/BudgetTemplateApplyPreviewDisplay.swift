import Foundation

/// Prepared Apply confirmation copy. Views render this; they do not format
/// money or decide To Budget vs Total Saved.
struct BudgetTemplateApplyPreviewDisplay: Equatable, Sendable {
    struct Category: Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var currentText: String
        var proposedText: String
        var contributions: [Contribution]
    }

    struct Contribution: Equatable, Identifiable, Sendable {
        var id: Int
        var title: String
        var amountText: String
    }

    var assignedText: String
    var leftoverTitle: String
    var leftoverText: String
    var changeCountText: String
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
        randomized: Bool,
        month: String
    ) -> BudgetTemplateApplyPreviewDisplay {
        let currency = preview.currency
        return BudgetTemplateApplyPreviewDisplay(
            assignedText: money(
                preview.assigned,
                currency: currency,
                randomized: randomized,
                seed: "template-apply-assigned-\(month)"
            ),
            leftoverTitle: leftoverTitle(isTrackingBudget: preview.isTrackingBudget),
            leftoverText: money(
                preview.leftover,
                currency: currency,
                randomized: randomized,
                seed: "template-apply-leftover-\(month)"
            ),
            changeCountText: changeCountText(preview.categories.count),
            categories: preview.categories.map { category in
                Category(
                    id: category.categoryID,
                    name: category.name.actualistCategoryNameParts.name,
                    currentText: money(
                        category.current,
                        currency: currency,
                        randomized: randomized,
                        seed: "template-apply-\(category.categoryID)-current"
                    ),
                    proposedText: money(
                        category.proposed,
                        currency: currency,
                        randomized: randomized,
                        seed: "template-apply-\(category.categoryID)-proposed"
                    ),
                    contributions: contributions(
                        category,
                        currency: currency,
                        randomized: randomized
                    )
                )
            }
        )
    }

    private static func contributions(
        _ category: BudgetTemplateApplyPreview.Category,
        currency: BudgetCurrency,
        randomized: Bool
    ) -> [Contribution] {
        guard category.perTemplate.count > 1 else {
            return []
        }
        return category.perTemplate.enumerated().map { index, amount in
            Contribution(
                id: index,
                title: contributionTitle(category, index: index),
                amountText: BudgetTemplateAmountInput.contributionText(
                    minorUnits: amount,
                    currency: currency,
                    randomized: randomized,
                    seed: "template-apply-\(category.categoryID)-\(index)"
                )
            )
        }
    }

    private static func contributionTitle(
        _ category: BudgetTemplateApplyPreview.Category,
        index: Int
    ) -> String {
        if category.drafts.count == category.perTemplate.count,
           category.drafts.indices.contains(index) {
            return category.drafts[index].kind.title
        }
        return "Template \(index + 1)"
    }

    private static func money(
        _ amount: Int,
        currency: BudgetCurrency,
        randomized: Bool,
        seed: String
    ) -> String {
        if randomized {
            return PrivacyDisplay.money(amount, seed: seed, currency: currency)
        }
        return currency.formatted(amount)
    }
}
