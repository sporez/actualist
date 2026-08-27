import Testing
@testable import Actualist

@Suite("Budget template engine schedules and spend")
struct BudgetTemplateEngineScheduleTests {
    private let engine = BudgetTemplateEngine()

    @Test func spendSpreadsRemainingAmountAcrossInclusiveMonths() throws {
        let amounts = try writeAmounts(
            categories: [
                "trip": category(json: spend(amount: 300, month: "2026-09", from: "2026-07"))
            ]
        )
        #expect(amounts["trip"] == 10_000)
    }

    @Test func spendUsesFromMonthLeftoverMinusSpentThenLaterBudgets() throws {
        let amounts = try writeAmounts(
            categories: [
                "trip": category(
                    json: spend(amount: 300, month: "2026-07", from: "2026-05"),
                    leftoverByMonth: [202605: 8_000],
                    spentByMonth: [202605: -2_000],
                    budgetedByMonth: [202606: 5_000]
                )
            ]
        )
        // already = (8000 - -2000) + 5000 = 15000; (30000-15000)/1 = 15000
        #expect(amounts["trip"] == 15_000)
    }

    @Test func spendWithPassedNonRepeatingTargetReturnsZeroWhenAlone() throws {
        let amounts = try writeAmounts(
            categories: [
                "trip": category(json: spend(amount: 300, month: "2026-05", from: "2026-04"))
            ]
        )
        #expect(amounts["trip"] == 0)
    }

    @Test func monthlyScheduleInCurrentMonthBudgetsTheSignedTarget() throws {
        let amounts = try writeAmounts(
            categories: [
                "rent": category(
                    json: schedule(name: "Rent"),
                    resolvedSchedules: [
                        "Rent": monthlySchedule(name: "Rent", target: 125_000)
                    ]
                )
            ]
        )
        #expect(amounts["rent"] == 125_000)
    }

    @Test func monthlyScheduleSubtractsLeftoverWhenFundsAreShort() throws {
        let amounts = try writeAmounts(
            categories: [
                "rent": category(
                    json: schedule(name: "Rent"),
                    fromLastMonth: 25_000,
                    resolvedSchedules: [
                        "Rent": monthlySchedule(name: "Rent", target: 125_000)
                    ]
                )
            ]
        )
        #expect(amounts["rent"] == 100_000)
    }

    @Test func yearlySinkingScheduleSpreadsAcrossRemainingMonths() throws {
        let amounts = try writeAmounts(
            categories: [
                "insurance": category(
                    json: schedule(name: "Insurance"),
                    resolvedSchedules: [
                        "Insurance": BudgetTemplateEngine.ResolvedSchedule(
                            name: "Insurance",
                            amount: -120_000,
                            nextDate: "2026-12-01",
                            monthsUntil: 5,
                            interval: 1,
                            frequency: "yearly",
                            completed: false,
                            full: false,
                            isRepeating: true,
                            recurrence: nil,
                            monthlyRepeatingTarget: 120_000
                        )
                    ]
                )
            ]
        )
        #expect(amounts["insurance"] == 20_000)
    }

    @Test func missingScheduleNameIsRefused() throws {
        do {
            _ = try writeAmounts(
                categories: [
                    "rent": category(json: schedule(name: "Rent"))
                ],
                monthSources: .init()
            )
            Issue.record("Expected a missing schedule to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Schedule Rent does not exist"))
        }
    }

    @Test func scheduleAndByMustShareTheLowestPriority() throws {
        do {
            _ = try engine.validateByScheduleAndSpend(
                try #require(try engine.decodeSupportedEntries(json: """
                    [
                      {"directive":"template","type":"by","amount":10,"month":"2026-09","priority":1},
                      {"directive":"template","type":"schedule","name":"Rent","priority":2}
                    ]
                    """)),
                monthValue: 202607,
                activeScheduleNames: ["Rent"]
            )
            Issue.record("Expected mixed schedule and by priorities to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("same priority level"))
            #expect(reason.contains("1"))
        }
    }

    private func writeAmounts(
        categories: [String: BudgetTemplateEngine.Category],
        monthSources: BudgetTemplateEngine.MonthSources = BudgetTemplateEngine.MonthSources(
            activeScheduleNames: ["Rent", "Insurance"]
        )
    ) throws -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: try engine.computeWrites(
                categories: categories,
                orderedCategoryIDs: Array(categories.keys),
                monthValue: 202607,
                availableBudget: 1_000_000,
                monthSources: monthSources
            ).map { ($0.categoryID, $0.amount) }
        )
    }

    private func category(
        json: String,
        fromLastMonth: Int = 0,
        leftoverByMonth: [Int: Int] = [:],
        spentByMonth: [Int: Int] = [:],
        budgetedByMonth: [Int: Int] = [:],
        resolvedSchedules: [String: BudgetTemplateEngine.ResolvedSchedule] = [:]
    ) throws -> BudgetTemplateEngine.Category {
        let entries = try #require(try engine.decodeSupportedEntries(json: json))
        return .init(
            entries: entries,
            fromLastMonth: fromLastMonth,
            copiedBudgetedByLookBack: [:],
            budgetedByMonth: budgetedByMonth,
            leftoverByMonth: leftoverByMonth,
            spentByMonth: spentByMonth,
            resolvedSchedules: resolvedSchedules
        )
    }

    private func spend(amount: Double, month: String, from: String) -> String {
        """
        [{
          "directive":"template",
          "type":"spend",
          "amount":\(amount),
          "month":"\(month)",
          "from":"\(from)",
          "priority":0
        }]
        """
    }

    private func schedule(name: String) -> String {
        """
        [{
          "directive":"template",
          "type":"schedule",
          "name":"\(name)",
          "priority":0
        }]
        """
    }

    private func monthlySchedule(name: String, target: Int) -> BudgetTemplateEngine.ResolvedSchedule {
        BudgetTemplateEngine.ResolvedSchedule(
            name: name,
            amount: -target,
            nextDate: "2026-07-01",
            monthsUntil: 0,
            interval: 1,
            frequency: "monthly",
            completed: false,
            full: false,
            isRepeating: false,
            recurrence: nil,
            monthlyRepeatingTarget: target
        )
    }
}
