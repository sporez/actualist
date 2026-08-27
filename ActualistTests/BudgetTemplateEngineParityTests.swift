import Testing
@testable import Actualist

@Suite("Budget template engine Actual parity")
struct BudgetTemplateEngineParityTests {
    private let engine = BudgetTemplateEngine()

    @Test func singlePriorityCategoryClampsToInsufficientAvailableBudget() throws {
        let amounts = try writeAmounts(
            categories: [
                "later": category(json: simple(monthly: 50, priority: 1))
            ],
            order: ["later"],
            availableBudget: 2_000
        )
        #expect(amounts["later"] == 2_000)
    }

    @Test func samePriorityCategoriesShareInsufficientFundsInBudgetOrder() throws {
        let amounts = try writeAmounts(
            categories: [
                "z-first": category(json: simple(monthly: 50, priority: 1)),
                "a-second": category(json: simple(monthly: 50, priority: 1))
            ],
            order: ["z-first", "a-second"],
            availableBudget: 3_000
        )
        #expect(amounts["z-first"] == 3_000)
        #expect(amounts["a-second"] == 0)
    }

    @Test func samePriorityIDsThatSortOppositeBudgetOrderDoNotStealFunds() throws {
        let amounts = try writeAmounts(
            categories: [
                "a-second": category(json: simple(monthly: 50, priority: 1)),
                "z-first": category(json: simple(monthly: 50, priority: 1))
            ],
            order: ["z-first", "a-second"],
            availableBudget: 3_000
        )
        #expect(amounts["z-first"] == 3_000)
        #expect(amounts["a-second"] == 0)
    }

    @Test func weightedRemaindersDivideExactly() throws {
        let amounts = try writeAmounts(
            categories: [
                "zz": category(json: remainder(weight: 1)),
                "aa": category(json: remainder(weight: 2))
            ],
            order: ["zz", "aa"],
            availableBudget: 30_000
        )
        #expect(amounts["zz"] == 10_000)
        #expect(amounts["aa"] == 20_000)
    }

    @Test func weightedRemainderRoundingResidualFollowsBudgetOrder() throws {
        let amounts = try writeAmounts(
            categories: [
                "aa": category(json: remainder(weight: 1)),
                "zz": category(json: remainder(weight: 1))
            ],
            order: ["zz", "aa"],
            availableBudget: 1
        )
        #expect(amounts["zz"] == 1)
        #expect(amounts["aa"] == 0)
    }

    @Test func remainderLimitRedistributesLeftoverToTheNextCategory() throws {
        let amounts = try writeAmounts(
            categories: [
                "zz-capped": category(
                    json: remainder(
                        weight: 1,
                        limit: #"{"amount":10,"period":"monthly","hold":false,"start":null}"#
                    )
                ),
                "aa-open": category(json: remainder(weight: 1))
            ],
            order: ["zz-capped", "aa-open"],
            availableBudget: 10_000
        )
        #expect(amounts["zz-capped"] == 1_000)
        #expect(amounts["aa-open"] == 9_000)
    }

    @Test func dailyUpToScalesByDaysInMonth() throws {
        let july = try writeAmounts(
            categories: [
                "daily": category(
                    json: simple(
                        monthly: 100,
                        priority: 0,
                        limit: #"{"amount":1,"period":"daily","hold":false}"#
                    )
                )
            ],
            order: ["daily"],
            monthValue: 202607,
            availableBudget: 100_000
        )
        let february = try writeAmounts(
            categories: [
                "daily": category(
                    json: simple(
                        monthly: 100,
                        priority: 0,
                        limit: #"{"amount":1,"period":"daily","hold":false}"#
                    )
                )
            ],
            order: ["daily"],
            monthValue: 202602,
            availableBudget: 100_000
        )
        #expect(july["daily"] == 3_100)
        #expect(february["daily"] == 2_800)
    }

    @Test func weeklyUpToUsesTheExplicitStartDate() throws {
        let amounts = try writeAmounts(
            categories: [
                "weekly": category(
                    json: simple(
                        monthly: 1_000,
                        priority: 0,
                        limit: #"{"amount":10,"period":"weekly","hold":false,"start":"2026-07-03"}"#
                    )
                )
            ],
            order: ["weekly"],
            availableBudget: 100_000
        )
        #expect(amounts["weekly"] == 5_000)
    }

    @Test func monthlyUpToHoldsOrReleasesCarriedExcess() throws {
        let hold = try writeAmounts(
            categories: [
                "buffer": category(
                    json: simple(
                        monthly: 100,
                        priority: 0,
                        limit: #"{"amount":50,"period":"monthly","hold":true,"start":null}"#
                    ),
                    fromLastMonth: 8_000
                )
            ],
            order: ["buffer"],
            availableBudget: 100_000
        )
        let release = try writeAmounts(
            categories: [
                "buffer": category(
                    json: simple(
                        monthly: 100,
                        priority: 0,
                        limit: #"{"amount":50,"period":"monthly","hold":false,"start":null}"#
                    ),
                    fromLastMonth: 8_000
                )
            ],
            order: ["buffer"],
            availableBudget: 100_000
        )
        #expect(hold["buffer"] == 0)
        #expect(release["buffer"] == -3_000)
    }

    @Test func periodicDayWeekMonthAndYearCountOccurrencesInMonth() throws {
        #expect(
            try engine.periodicAmount(
                periodic(amount: 1, period: "day", interval: 1, starting: "2026-07-01"),
                monthValue: 202607
            ) == 3_100
        )
        #expect(
            try engine.periodicAmount(
                periodic(amount: 10, period: "week", interval: 1, starting: "2026-07-01"),
                monthValue: 202607
            ) == 5_000
        )
        #expect(
            try engine.periodicAmount(
                periodic(amount: 45, period: "month", interval: 1, starting: "2026-07-01"),
                monthValue: 202607
            ) == 4_500
        )
        #expect(
            try engine.periodicAmount(
                periodic(amount: 120, period: "year", interval: 1, starting: "2025-07-01"),
                monthValue: 202607
            ) == 12_000
        )
        #expect(
            try engine.periodicAmount(
                periodic(amount: 120, period: "year", interval: 1, starting: "2026-08-01"),
                monthValue: 202607
            ) == 0
        )
    }

    @Test func repeatingByAdvancesAPassedAnnualTarget() throws {
        let decoded = try #require(
            try engine.decodeSupportedEntries(
                json: """
                    [{
                      "directive": "template",
                      "type": "by",
                      "amount": 120,
                      "month": "2026-06",
                      "annual": true,
                      "repeat": 1,
                      "priority": 0
                    }]
                    """
            )
        )
        let amounts = try writeAmounts(
            categories: [
                "renewal": .init(entries: decoded, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            order: ["renewal"],
            monthValue: 202608,
            availableBudget: 100_000
        )
        #expect(amounts["renewal"] == 1_091)
    }

    @Test func hideFractionRemainderAbsorbsLeftoverWholeUnitsInBudgetOrder() throws {
        let hidden = BudgetTemplateEngine(
            currency: BudgetCurrency.catalog(code: "USD", hideFraction: true)
        )
        let amounts = try writeAmounts(
            using: hidden,
            categories: [
                "aa": category(json: remainder(weight: 1)),
                "zz": category(json: remainder(weight: 1))
            ],
            order: ["zz", "aa"],
            availableBudget: 10_050
        )
        #expect(amounts["zz"] == 5_000)
        #expect(amounts["aa"] == 5_050)
    }

    @Test func goalOnlyEntriesAreSkippedWithoutApplyingABudget() throws {
        let decoded = try engine.decodeSupportedEntries(
            json: #"[{"directive":"goal","type":"goal","amount":100}]"#
        )
        #expect(decoded == nil)
    }

    @Test func validActualRemainderAndSimpleGoalDefsAreAccepted() throws {
        let remainderEntries = try #require(
            try engine.decodeSupportedEntries(
                json: #"[{"directive":"template","type":"remainder","weight":1,"priority":null}]"#
            )
        )
        let simpleEntries = try #require(
            try engine.decodeSupportedEntries(
                json: #"[{"directive":"template","type":"simple","monthly":10,"priority":0}]"#
            )
        )
        #expect(remainderEntries.count == 1)
        #expect(simpleEntries.count == 1)
    }

    @Test func missingDirectiveIsRejected() throws {
        #expect(throws: LocalFirstError.self) {
            _ = try engine.decodeSupportedEntries(
                json: #"[{"type":"simple","monthly":10,"priority":0}]"#
            )
        }
    }

    @Test func malformedDirectiveIsRejected() throws {
        #expect(throws: LocalFirstError.self) {
            _ = try engine.decodeSupportedEntries(
                json: #"[{"directive":"nope","type":"simple","monthly":10,"priority":0}]"#
            )
        }
    }

    @Test func missingRemainderWeightIsRejected() throws {
        #expect(throws: LocalFirstError.self) {
            _ = try engine.decodeSupportedEntries(
                json: #"[{"directive":"template","type":"remainder"}]"#
            )
        }
    }

    @Test func refillFromIntMinCarryoverThrowsInsteadOfTrapping() throws {
        let decoded = try #require(
            try engine.decodeSupportedEntries(
                json: """
                    [{
                      "directive": "template",
                      "type": "limit",
                      "amount": 10,
                      "period": "monthly",
                      "hold": false,
                      "start": null,
                      "priority": null
                    },
                    {
                      "directive": "template",
                      "type": "refill",
                      "priority": 0
                    }]
                    """
            )
        )
        #expect(throws: LocalFirstError.numericValueOutOfRange) {
            _ = try engine.computeWrites(
                categories: [
                    "buffer": .init(
                        entries: decoded,
                        fromLastMonth: Int.min,
                        copiedBudgetedByLookBack: [:]
                    )
                ],
                orderedCategoryIDs: ["buffer"],
                monthValue: 202607,
                availableBudget: 100_000
            )
        }
    }

    @Test func remainderLimitCarryNearIntMaxThrowsInsteadOfTrapping() throws {
        let decoded = try #require(
            try engine.decodeSupportedEntries(
                json: remainder(
                    weight: 1,
                    limit: #"{"amount":10,"period":"monthly","hold":false,"start":null}"#
                )
            )
        )
        #expect(throws: LocalFirstError.numericValueOutOfRange) {
            _ = try engine.computeWrites(
                categories: [
                    "capped": .init(
                        entries: decoded,
                        fromLastMonth: Int.max,
                        copiedBudgetedByLookBack: [:]
                    )
                ],
                orderedCategoryIDs: ["capped"],
                monthValue: 202607,
                availableBudget: 100_000
            )
        }
    }

    private func writeAmounts(
        using engine: BudgetTemplateEngine? = nil,
        categories: [String: BudgetTemplateEngine.Category],
        order: [String],
        monthValue: Int = 202607,
        availableBudget: Int
    ) throws -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: try (engine ?? self.engine).computeWrites(
                categories: categories,
                orderedCategoryIDs: order,
                monthValue: monthValue,
                availableBudget: availableBudget
            ).map { ($0.categoryID, $0.amount) }
        )
    }

    private func category(
        json: String,
        fromLastMonth: Int = 0,
        copiedBudgetedByLookBack: [Int: Int] = [:]
    ) throws -> BudgetTemplateEngine.Category {
        let entries = try #require(try engine.decodeSupportedEntries(json: json))
        return .init(
            entries: entries,
            fromLastMonth: fromLastMonth,
            copiedBudgetedByLookBack: copiedBudgetedByLookBack
        )
    }

    private func simple(monthly: Double, priority: Int, limit: String? = nil) -> String {
        var fields = [
            #""directive":"template""#,
            #""type":"simple""#,
            #""monthly":\#(monthly)"#,
            #""priority":\#(priority)"#
        ]
        if let limit {
            fields.append(#""limit":\#(limit)"#)
        }
        return "[{\(fields.joined(separator: ","))}]"
    }

    private func remainder(weight: Double, limit: String? = nil) -> String {
        var fields = [
            #""directive":"template""#,
            #""type":"remainder""#,
            #""weight":\#(weight)"#,
            #""priority":null"#
        ]
        if let limit {
            fields.append(#""limit":\#(limit)"#)
        }
        return "[{\(fields.joined(separator: ","))}]"
    }

    private func periodic(
        amount: Double,
        period: String,
        interval: Int,
        starting: String
    ) throws -> BudgetTemplateEntry {
        let json = """
            [{
              "directive": "template",
              "type": "periodic",
              "amount": \(amount),
              "period": {"period": "\(period)", "amount": \(interval)},
              "starting": "\(starting)",
              "priority": 0
            }]
            """
        let entries = try #require(try engine.decodeSupportedEntries(json: json))
        return entries[0]
    }
}
