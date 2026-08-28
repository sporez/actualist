import Testing
@testable import Actualist

@Suite("Budget template engine aggregates")
struct BudgetTemplateEngineAggregateTests {
    private let engine = BudgetTemplateEngine()

    @Test func averageUsesCompleteHistoryMeanAsPositiveBudgetNeed() throws {
        // Actual getCategoryAverage([-100, -200, -300]) = -200, then runAverage flips sign.
        let amounts = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3),
                    activityByMonth: [202606: -10_000, 202605: -20_000, 202604: -30_000],
                    firstRelevantMonth: 202604
                )
            ]
        )
        #expect(amounts["food"] == 20_000)
    }

    @Test func averageUsesCompleteSixMonthHistory() throws {
        let amounts = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 6),
                    activityByMonth: [
                        202606: -10_000,
                        202605: -20_000,
                        202604: -30_000,
                        202603: -40_000,
                        202602: -50_000,
                        202601: -60_000
                    ],
                    firstRelevantMonth: 202601
                )
            ]
        )
        #expect(amounts["food"] == 35_000)
    }

    @Test func averageShortensWindowToFirstRelevantHistoryMonth() throws {
        // Two real months of spending, template asks for six. Actual does not pad
        // the four earlier months with zero.
        let amounts = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 6),
                    activityByMonth: [202606: -10_000, 202605: -20_000],
                    firstRelevantMonth: 202605
                )
            ]
        )
        #expect(amounts["food"] == 15_000)
    }

    @Test func averageIncludesGapsAfterFirstRelevantMonth() throws {
        let amounts = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3),
                    activityByMonth: [202606: -10_000, 202604: -20_000],
                    firstRelevantMonth: 202604
                )
            ]
        )
        #expect(amounts["food"] == 10_000)
    }

    @Test func averageAnchorsFutureMonthsToCompletedHistory() throws {
        let activity = [202606: -10_000, 202605: -20_000]
        let current = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 6),
                    activityByMonth: activity,
                    firstRelevantMonth: 202605
                )
            ],
            monthValue: 202608,
            currentMonthValue: 202608
        )
        let oneMonthAhead = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 6),
                    activityByMonth: activity,
                    firstRelevantMonth: 202605
                )
            ],
            monthValue: 202609,
            currentMonthValue: 202608
        )
        let severalMonthsAhead = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 6),
                    activityByMonth: activity,
                    firstRelevantMonth: 202605
                )
            ],
            monthValue: 202611,
            currentMonthValue: 202608
        )
        let pastMonth = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 6),
                    activityByMonth: activity,
                    firstRelevantMonth: 202605
                )
            ],
            monthValue: 202607,
            currentMonthValue: 202608
        )

        // Current / +1 / +several all start at July (last completed month):
        // July 0 + June -100 + May -200.
        #expect(current["food"] == 10_000)
        #expect(oneMonthAhead["food"] == 10_000)
        #expect(severalMonthsAhead["food"] == 10_000)
        // Applying to a past month starts at that month's predecessor (June).
        #expect(pastMonth["food"] == 15_000)
    }

    @Test func averageKeepsNetPositiveActivity() throws {
        let amounts = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 2),
                    activityByMonth: [202606: 10_000, 202605: 20_000],
                    firstRelevantMonth: 202605
                )
            ]
        )
        #expect(amounts["food"] == 15_000)
    }

    @Test func averageAppliesPercentAndFixedAdjustmentsBeforeRounding() throws {
        let percent = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3, adjustment: 10, adjustmentType: "percent"),
                    activityByMonth: [202606: -10_000, 202605: -20_000, 202604: -30_000],
                    firstRelevantMonth: 202604
                )
            ]
        )
        let decreased = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3, adjustment: -10, adjustmentType: "percent"),
                    activityByMonth: [202606: -10_000, 202605: -20_000, 202604: -30_000],
                    firstRelevantMonth: 202604
                )
            ]
        )
        let fixed = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3, adjustment: 5, adjustmentType: "fixed"),
                    activityByMonth: [202606: -10_000, 202605: -20_000, 202604: -30_000],
                    firstRelevantMonth: 202604
                )
            ]
        )

        #expect(percent["food"] == 22_000)
        #expect(decreased["food"] == 18_000)
        #expect(fixed["food"] == 20_500)
    }

    @Test func averageRoundsSignedMeanLikeJavaScriptMathRound() throws {
        // Actual rounds the signed mean first: Math.round(-301 / 2) = -150, then flips.
        let halfUnit = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 2),
                    activityByMonth: [202606: -100, 202605: -201],
                    firstRelevantMonth: 202605
                )
            ]
        )
        // Mixed history from Actual's runAverage tests: Math.round(-200 / 3) = -67.
        let mixed = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3),
                    activityByMonth: [202606: -100, 202605: 200, 202604: -300],
                    firstRelevantMonth: 202604
                )
            ]
        )
        // Percent adjustment after the integer mean: 67 * 1.1 = 73.7 → 74.
        let percent = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3, adjustment: 10, adjustmentType: "percent"),
                    activityByMonth: [202606: -100, 202605: 200, 202604: -300],
                    firstRelevantMonth: 202604
                )
            ]
        )
        #expect(halfUnit["food"] == 150)
        #expect(mixed["food"] == 67)
        #expect(percent["food"] == 74)
    }

    @Test func averageFixedAdjustmentUsesCurrencyMinorUnits() throws {
        // Actual amountToInteger(11, 2) = 1100 added after the flipped mean.
        let usd = try writeAmounts(
            categories: [
                "food": category(
                    json: average(numMonths: 3, adjustment: 11, adjustmentType: "fixed"),
                    activityByMonth: [202606: -10_000, 202605: -10_000, 202604: -10_000],
                    firstRelevantMonth: 202604
                )
            ]
        )
        let jpyEngine = BudgetTemplateEngine(currency: .jpy)
        let jpy = try writeAmounts(
            using: jpyEngine,
            categories: [
                "food": try category(
                    engine: jpyEngine,
                    json: average(numMonths: 3, adjustment: 11, adjustmentType: "fixed"),
                    activityByMonth: [202606: -10_000, 202605: -10_000, 202604: -10_000],
                    firstRelevantMonth: 202604
                )
            ]
        )
        #expect(usd["food"] == 11_100)
        #expect(jpy["food"] == 10_011)
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
        using engine: BudgetTemplateEngine? = nil,
        categories: [String: BudgetTemplateEngine.Category],
        order: [String]? = nil,
        monthValue: Int = 202607,
        currentMonthValue: Int? = nil,
        availableBudget: Int = 100_000,
        monthSources: BudgetTemplateEngine.MonthSources = BudgetTemplateEngine.MonthSources()
    ) throws -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: try (engine ?? self.engine).computeWrites(
                categories: categories,
                orderedCategoryIDs: order ?? Array(categories.keys),
                monthValue: monthValue,
                availableBudget: availableBudget,
                monthSources: monthSources,
                currentMonthValue: currentMonthValue ?? monthValue
            ).map { ($0.categoryID, $0.amount) }
        )
    }

    private func category(
        engine: BudgetTemplateEngine? = nil,
        json: String,
        activityByMonth: [Int: Int] = [:],
        firstRelevantMonth: Int? = nil
    ) throws -> BudgetTemplateEngine.Category {
        let entries = try #require(try (engine ?? self.engine).decodeSupportedEntries(json: json))
        return .init(
            entries: entries,
            fromLastMonth: 0,
            copiedBudgetedByLookBack: [:],
            activityByMonth: activityByMonth,
            firstRelevantMonth: firstRelevantMonth
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
