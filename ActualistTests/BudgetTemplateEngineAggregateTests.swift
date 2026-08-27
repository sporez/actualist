import Testing
@testable import Actualist

@Suite("Budget template engine aggregates")
struct BudgetTemplateEngineAggregateTests {
    private let engine = BudgetTemplateEngine()

    @Test func averageUsesNegatedMeanOfPriorMonthActivity() throws {
        let amounts = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3),
                    activityByLookBack: [1: -10_000, 2: -20_000, 3: -30_000]
                )
            ],
            availableBudget: 100_000
        )
        #expect(amounts["food"] == 20_000)
    }

    @Test func averageTreatsMissingMonthsAsZero() throws {
        let amounts = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 2),
                    activityByLookBack: [1: -10_000]
                )
            ],
            availableBudget: 100_000
        )
        #expect(amounts["food"] == 5_000)
    }

    @Test func averageAppliesPercentAndFixedAdjustmentsBeforeRounding() throws {
        let percent = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3, adjustment: 10, adjustmentType: "percent"),
                    activityByLookBack: [1: -10_000, 2: -20_000, 3: -30_000]
                )
            ],
            availableBudget: 100_000
        )
        let decreased = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3, adjustment: -10, adjustmentType: "percent"),
                    activityByLookBack: [1: -10_000, 2: -20_000, 3: -30_000]
                )
            ],
            availableBudget: 100_000
        )
        let fixed = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3, adjustment: 5, adjustmentType: "fixed"),
                    activityByLookBack: [1: -10_000, 2: -20_000, 3: -30_000]
                )
            ],
            availableBudget: 100_000
        )

        #expect(percent["food"] == 22_000)
        #expect(decreased["food"] == 18_000)
        #expect(fixed["food"] == 20_500)
    }

    @Test func averageRoundsLikeJavaScriptMathRound() throws {
        // sum = -10_000 over 3 months → 3333.333… → 3333
        let amounts = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3),
                    activityByLookBack: [1: -10_000]
                )
            ],
            availableBudget: 100_000
        )
        #expect(amounts["food"] == 3_333)
    }

    @Test func percentageOfAllIncomeUsesCurrentOrPreviousMonthTotals() throws {
        let current = try writeAmounts(
            categories: [
                "savings": category(json: percentage(percent: 10, category: "all income"))
            ],
            availableBudget: 100_000,
            monthSources: .init(totalIncomeByLookBack: [0: 60_000, 1: 40_000])
        )
        let previous = try writeAmounts(
            categories: [
                "savings": category(
                    json: percentage(percent: 10, category: "all income", previous: true)
                )
            ],
            availableBudget: 100_000,
            monthSources: .init(totalIncomeByLookBack: [0: 60_000, 1: 40_000])
        )

        #expect(current["savings"] == 6_000)
        #expect(previous["savings"] == 4_000)
    }

    @Test func percentageOfAvailableFundsUsesPriorityStartNotSiblingRemainder() throws {
        let amounts = try writeAmounts(
            categories: [
                "first": category(json: percentage(percent: 10, category: "available funds")),
                "second": category(json: percentage(percent: 10, category: "available funds"))
            ],
            order: ["first", "second"],
            availableBudget: 12_345
        )
        #expect(amounts["first"] == 1_235)
        #expect(amounts["second"] == 1_235)
    }

    @Test func percentageOfNamedIncomeCategoryMatchesIdOrLocalizedName() throws {
        let sources = BudgetTemplateEngine.MonthSources(
            incomeActivityByCategoryID: ["salary": [0: 80_000]],
            incomeCategoryIDs: ["salary"],
            incomeCategoryIDByLocalizedName: ["salary": "salary"]
        )
        let byName = try writeAmounts(
            categories: [
                "savings": category(json: percentage(percent: 50, category: "Salary"))
            ],
            availableBudget: 100_000,
            monthSources: sources
        )
        let byID = try writeAmounts(
            categories: [
                "savings": category(json: percentage(percent: 50, category: "salary"))
            ],
            availableBudget: 100_000,
            monthSources: sources
        )

        #expect(byName["savings"] == 40_000)
        #expect(byID["savings"] == 40_000)
    }

    @Test func percentageOfNegativeIncomeIsClampedToZero() throws {
        let amounts = try writeAmounts(
            categories: [
                "savings": category(json: percentage(percent: 10, category: "all income"))
            ],
            availableBudget: 100_000,
            monthSources: .init(totalIncomeByLookBack: [0: -5_000])
        )
        #expect(amounts["savings"] == 0)
    }

    @Test func percentageOfExpenseCategoryIsRefused() throws {
        do {
            _ = try writeAmounts(
                categories: [
                    "savings": category(json: percentage(percent: 10, category: "Food"))
                ],
                availableBudget: 100_000
            )
            Issue.record("Expected a non-income percentage source to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Food"))
            #expect(reason.contains("not found in available income categories"))
        }
    }

    @Test func twoGoalsInOneCategoryAreRefused() throws {
        do {
            _ = try engine.decodeSupportedEntries(
                json: """
                    [
                      {"directive":"goal","type":"goal","amount":100,"priority":null},
                      {"directive":"goal","type":"goal","amount":200,"priority":null}
                    ]
                    """
            )
            Issue.record("Expected two goals to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Only one #goal is allowed per category"))
        }
    }

    @Test func twoSpendTemplatesInOneCategoryAreRefused() throws {
        do {
            _ = try engine.decodeSupportedEntries(
                json: """
                    [
                      {"directive":"template","type":"spend","amount":100,"month":"2026-08","from":"2026-06","priority":0},
                      {"directive":"template","type":"spend","amount":50,"month":"2026-09","from":"2026-07","priority":0}
                    ]
                    """
            )
            Issue.record("Expected two spend templates to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Only one spend template is allowed per category"))
        }
    }

    private func writeAmounts(
        categories: [String: BudgetTemplateEngine.Category],
        order: [String]? = nil,
        availableBudget: Int,
        monthSources: BudgetTemplateEngine.MonthSources = BudgetTemplateEngine.MonthSources()
    ) throws -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: try engine.computeWrites(
                categories: categories,
                orderedCategoryIDs: order ?? Array(categories.keys),
                monthValue: 202607,
                availableBudget: availableBudget,
                monthSources: monthSources
            ).map { ($0.categoryID, $0.amount) }
        )
    }

    private func category(
        json: String,
        activityByLookBack: [Int: Int] = [:]
    ) throws -> BudgetTemplateEngine.Category {
        let entries = try #require(try engine.decodeSupportedEntries(json: json))
        return .init(
            entries: entries,
            fromLastMonth: 0,
            copiedBudgetedByLookBack: [:],
            activityByLookBack: activityByLookBack
        )
    }

    private func average(
        numMonths: Int,
        adjustment: Double? = nil,
        adjustmentType: String? = nil
    ) -> String {
        var fields = [
            #""directive":"template""#,
            #""type":"average""#,
            #""numMonths":\#(numMonths)"#,
            #""priority":0"#
        ]
        if let adjustment {
            fields.append(#""adjustment":\#(adjustment)"#)
        }
        if let adjustmentType {
            fields.append(#""adjustmentType":"\#(adjustmentType)""#)
        }
        return "[{\(fields.joined(separator: ","))}]"
    }

    private func percentage(percent: Double, category: String, previous: Bool = false) -> String {
        """
        [{
          "directive":"template",
          "type":"percentage",
          "percent":\(percent),
          "previous":\(previous),
          "category":"\(category)",
          "priority":0
        }]
        """
    }
}
