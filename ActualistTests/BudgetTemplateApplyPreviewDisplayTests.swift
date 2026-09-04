import Foundation
import Testing
@testable import Actualist

struct BudgetTemplateApplyPreviewDisplayTests {
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)
    )!

    @Test func leftoverTitleFollowsBudgetType() {
        #expect(BudgetTemplateApplyPreviewDisplay.leftoverTitle(isTrackingBudget: false) == "To Budget")
        #expect(BudgetTemplateApplyPreviewDisplay.leftoverTitle(isTrackingBudget: true) == "Total Saved")
        #expect(BudgetTemplateApplyPreviewDisplay.changeCountText(0) == "None")
        #expect(BudgetTemplateApplyPreviewDisplay.changeCountText(1) == "1 category")
        #expect(BudgetTemplateApplyPreviewDisplay.changeCountText(3) == "3 categories")
    }

    @Test func formatsTotalsAndHidesSingleTemplateContribution() {
        let display = BudgetTemplateApplyPreviewDisplay.make(
            preview: BudgetTemplateApplyPreview(
                assigned: 40_000,
                leftover: 12_000,
                isTrackingBudget: false,
                currency: .usd,
                categories: [
                    BudgetTemplateApplyPreview.Category(
                        categoryID: "groceries",
                        name: "🛒 Groceries",
                        current: 0,
                        proposed: 40_000,
                        perTemplate: [40_000],
                        drafts: [.monthlyFixed(amount: 400, now: now)]
                    )
                ]
            ),
            randomized: false,
            month: "2026-07"
        )
        #expect(display.assignedText == BudgetCurrency.usd.formatted(40_000))
        #expect(display.leftoverTitle == "To Budget")
        #expect(display.leftoverText == BudgetCurrency.usd.formatted(12_000))
        #expect(display.changeCountText == "1 category")
        #expect(display.categories.map(\.name) == ["Groceries"])
        #expect(display.categories[0].currentText == BudgetCurrency.usd.formatted(0))
        #expect(display.categories[0].proposedText == BudgetCurrency.usd.formatted(40_000))
        #expect(display.categories[0].contributions.isEmpty)
    }

    @Test func showsPerTemplateContributionsAndFallbackTitles() {
        let labeled = BudgetTemplateApplyPreviewDisplay.make(
            preview: preview(
                categories: [
                    BudgetTemplateApplyPreview.Category(
                        categoryID: "groceries",
                        name: "Groceries",
                        current: 0,
                        proposed: 5_000,
                        perTemplate: [1_000, 4_000],
                        drafts: [.monthlyFixed(amount: 10, now: now), .remainder()]
                    )
                ]
            ),
            randomized: false,
            month: "2026-07"
        )
        #expect(labeled.categories[0].contributions.map(\.title) == ["Fixed Amount", "Remainder"])
        #expect(labeled.categories[0].contributions.map(\.amountText) == [
            BudgetCurrency.usd.formatted(1_000),
            BudgetCurrency.usd.formatted(4_000),
        ])

        let fallback = BudgetTemplateApplyPreviewDisplay.make(
            preview: preview(
                categories: [
                    BudgetTemplateApplyPreview.Category(
                        categoryID: "percent",
                        name: "Percent",
                        current: 0,
                        proposed: 3_000,
                        perTemplate: [1_000, 2_000],
                        drafts: []
                    )
                ]
            ),
            randomized: false,
            month: "2026-07"
        )
        #expect(fallback.categories[0].contributions.map(\.title) == ["Template 1", "Template 2"])
    }

    @Test func privacyRandomizesAmounts() {
        let preview = preview(
            leftover: -500,
            isTracking: true,
            categories: [
                BudgetTemplateApplyPreview.Category(
                    categoryID: "groceries",
                    name: "Groceries",
                    current: 10_000,
                    proposed: 40_000,
                    perTemplate: [15_000, 25_000],
                    drafts: [.monthlyFixed(amount: 150, now: now), .remainder()]
                )
            ]
        )
        let display = BudgetTemplateApplyPreviewDisplay.make(
            preview: preview,
            randomized: true,
            month: "2026-07"
        )
        let assigned = PrivacyDisplay.money(
            40_000,
            seed: "template-apply-assigned-2026-07",
            currency: .usd
        )
        let leftover = PrivacyDisplay.money(
            -500,
            seed: "template-apply-leftover-2026-07",
            currency: .usd
        )
        #expect(display.leftoverTitle == "Total Saved")
        #expect(display.assignedText == assigned)
        #expect(display.leftoverText == leftover)
        #expect(
            display.categories[0].proposedText == PrivacyDisplay.money(
                40_000,
                seed: "template-apply-groceries-proposed",
                currency: .usd
            )
        )
        if BudgetCurrency.usd.formatted(40_000) != assigned {
            #expect(!display.assignedText.contains(BudgetCurrency.usd.formatted(40_000)))
        }
    }

    @Test func confirmationCommands() {
        #expect(BudgetTemplateConfirmation.monthFillEmpty.command(categoryID: nil) == .fillEmpty)
        #expect(BudgetTemplateConfirmation.monthOverwrite.command(categoryID: "x") == .overwrite)
        #expect(BudgetTemplateConfirmation.category.command(categoryID: nil) == nil)
        #expect(BudgetTemplateConfirmation.category.command(categoryID: "  ") == nil)
        #expect(BudgetTemplateConfirmation.category.command(categoryID: "groceries") == .category("groceries"))
    }

    private func preview(
        leftover: Int = 0,
        isTracking: Bool = false,
        categories: [BudgetTemplateApplyPreview.Category]
    ) -> BudgetTemplateApplyPreview {
        BudgetTemplateApplyPreview(
            assigned: categories.reduce(0) { $0 + $1.proposed },
            leftover: leftover,
            isTrackingBudget: isTracking,
            currency: .usd,
            categories: categories
        )
    }

    @Test func modifierLabelsAndNonContributingTemplatesStayAligned() {
        let display = BudgetTemplateApplyPreviewDisplay.make(
            preview: preview(
                categories: [
                    BudgetTemplateApplyPreview.Category(
                        categoryID: "rent",
                        name: "Rent",
                        current: 0,
                        proposed: 7_000,
                        perTemplate: [2_000, 0, 5_000],
                        drafts: [
                            .average(numMonths: 3, adjustment: .percent(-10)),
                            .balanceLimit(amount: 500),
                            .schedule(name: "Rent", full: true, adjustment: .fixed(20))
                        ]
                    )
                ]
            ),
            randomized: false,
            month: "2026-07"
        )

        #expect(display.categories[0].contributions.map(\.id) == [0, 2])
        #expect(display.categories[0].contributions.map(\.title) == [
            "3-month average (decreased by 10%)",
            "Cover Rent (increased by \(BudgetCurrency.usd.formatted(2_000)))"
        ])
    }
}
