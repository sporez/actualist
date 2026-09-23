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
                        drafts: [.monthlyFixed(amount: 400, now: now)],
                        metric: .init(kind: .available, before: 0, after: 40_000)
                    )
                ],
                availableBefore: 12_000,
                availableAfter: 12_000
            ),
            randomized: false
        )
        #expect(display.assignedText == BudgetCurrency.usd.formatted(40_000))
        #expect(display.leftoverTitle == "To Budget")
        #expect(display.leftoverAfterText == BudgetCurrency.usd.formatted(12_000))
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
                        drafts: [.monthlyFixed(amount: 10, now: now), .remainder()],
                        metric: .init(kind: .available, before: 0, after: 5_000)
                    )
                ]
            ),
            randomized: false
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
                        drafts: [],
                        metric: .init(kind: .available, before: 0, after: 3_000)
                    )
                ]
            ),
            randomized: false
        )
        #expect(fallback.categories[0].contributions.map(\.title) == ["Template 1", "Template 2"])
    }

    @Test func privacyRandomizesAmounts() {
        var preview = preview(
            leftover: -500,
            isTracking: true,
            categories: [
                BudgetTemplateApplyPreview.Category(
                    categoryID: "groceries",
                    name: "Groceries",
                    current: 10_000,
                    proposed: 40_000,
                    perTemplate: [15_000, 25_000],
                    drafts: [.monthlyFixed(amount: 150, now: now), .remainder()],
                    metric: .init(kind: .balance, before: 10_000, after: 40_000)
                )
            ]
        )
        preview.released = 500
        let display = BudgetTemplateApplyPreviewDisplay.make(
            preview: preview,
            randomized: true
        )
        #expect(display.leftoverTitle == "Total Saved")
        #expect(display.releasedTitle == "Reduced")
        #expect(display.releasedText == "Hidden")
        #expect(display.assignedText == "Hidden")
        #expect(display.leftoverAfterText == "Hidden")
        #expect(display.categories[0].proposedText == "Hidden")
        #expect(display.categories[0].name != "Groceries")
        #expect(display.categories[0].metricBeforeText == "Hidden")
        #expect(display.categories[0].metricAfterText == "Hidden")
        #expect(display.categories[0].contributions.allSatisfy { $0.amountText == "Hidden" })
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
                        ],
                        metric: .init(kind: .available, before: 0, after: 7_000)
                    )
                ]
            ),
            randomized: false
        )

        #expect(display.categories[0].contributions.map(\.id) == [0, 2])
        #expect(display.categories[0].contributions.map(\.title) == [
            "3-month average (decreased by 10%)",
            "Cover Rent (increased by \(BudgetCurrency.usd.formatted(2_000)))"
        ])
    }

    @Test func showsPartialFundingAndProjectedAvailableValues() {
        var category = BudgetTemplateApplyPreview.Category(
            categoryID: "rent",
            name: "Rent",
            current: 100,
            proposed: 100,
            perTemplate: [200],
            drafts: [],
            goalAfter: 200,
            metric: .init(kind: .available, before: 50, after: 50)
        )
        category.evaluatedDemand = 200
        category.shortfall = 100
        let preview = BudgetTemplateApplyPreview(
            assigned: 0,
            leftover: 0,
            isTrackingBudget: false,
            currency: .usd,
            categories: [category],
            fundingRequired: 200,
            stillNeeded: 100,
            availableBefore: 100,
            availableAfter: 0
        )

        let display = BudgetTemplateApplyPreviewDisplay.make(
            preview: preview,
            randomized: false
        )
        #expect(display.fundingRequiredText == BudgetCurrency.usd.formatted(200))
        #expect(display.stillNeededText == BudgetCurrency.usd.formatted(100))
        #expect(display.leftoverBeforeText == BudgetCurrency.usd.formatted(100))
        #expect(display.leftoverAfterText == BudgetCurrency.usd.formatted(0))
        #expect(display.categories[0].statusText == "Unfunded")
        #expect(display.categories[0].shortfallText == BudgetCurrency.usd.formatted(100))
        #expect(display.categories[0].targetDetailText == "Template target \(BudgetCurrency.usd.formatted(200))")
        #expect(!display.hasNonMoneyUpdates)
        #expect(display.noOpExplanation == "No funds are available for the remaining template targets.")
    }

    @Test func showsChangedGoalMetadataEvenWithoutAnAssignmentChange() {
        let category = BudgetTemplateApplyPreview.Category(
            categoryID: "savings",
            name: "Savings",
            current: 500,
            proposed: 500,
            perTemplate: [],
            drafts: [],
            isGoalOnlyUpdate: true,
            goalBefore: 10_000,
            goalAfter: 12_000,
            metric: .init(kind: .available, before: 500, after: 500)
        )
        let preview = BudgetTemplateApplyPreview(
            assigned: 0,
            leftover: 0,
            isTrackingBudget: false,
            currency: .usd,
            categories: [category],
            hasNonMoneyUpdates: true
        )

        let display = BudgetTemplateApplyPreviewDisplay.make(preview: preview, randomized: false)
        #expect(display.categories.map(\.id) == ["savings"])
        #expect(display.categories[0].targetDetailText == "Goal target \(BudgetCurrency.usd.formatted(10_000)) → \(BudgetCurrency.usd.formatted(12_000))")
        #expect(display.hasNonMoneyUpdates)
    }

    @Test func emptyCategoryListDistinguishesMissingFromAlreadyFundedTemplates() {
        let display = BudgetTemplateApplyPreviewDisplay.make(
            preview: preview(categories: []),
            randomized: false
        )
        #expect(display.noOpExplanation == "No eligible templates were found for this month.")

        var fullyFunded = preview(categories: [])
        fullyFunded.hasEligibleTemplates = true
        let funded = BudgetTemplateApplyPreviewDisplay.make(preview: fullyFunded, randomized: false)
        #expect(funded.noOpExplanation == "Assignments already match their template targets.")
    }
}
