import Testing
@testable import Actualist

@Suite("Budget template engine")
struct BudgetTemplateEngineTests {
    private let engine = BudgetTemplateEngine()

    @Test func rejectsEveryBoundedFieldBeforeCalculation() throws {
        let invalidEntries = [
            #"{"directive":"template","type":"simple","monthly":1000000001,"priority":0}"#,
            #"{"directive":"template","type":"simple","monthly":-1000000001,"priority":0}"#,
            #"{"directive":"template","type":"simple","monthly":10,"limit":{"amount":-1,"period":"monthly","hold":false,"start":null},"priority":0}"#,
            #"{"directive":"template","type":"limit","amount":-1,"period":"monthly","hold":false,"priority":null}"#,
            #"{"directive":"template","type":"simple","monthly":10,"percentage":101,"priority":0}"#,
            #"{"directive":"template","type":"average","numMonths":0,"priority":0}"#,
            #"{"directive":"template","type":"average","numMonths":1201,"priority":0}"#,
            #"{"directive":"template","type":"percentage","percent":101,"category":"all income","priority":0}"#,
            #"{"directive":"template","type":"periodic","amount":1,"period":{"period":"day","amount":1201},"starting":"2026-07-01","priority":0}"#,
            #"{"directive":"template","type":"copy","lookBack":1201,"priority":0}"#,
            #"{"directive":"template","type":"by","amount":10,"month":"2026-08","repeat":1201,"priority":0}"#,
            #"{"directive":"template","type":"simple","monthly":10,"priority":1001}"#,
            #"{"directive":"template","type":"remainder","weight":-1}"#
        ]

        for entry in invalidEntries {
            do {
                _ = try engine.decodeSupportedEntries(json: "[\(entry)]")
                Issue.record("Expected the out-of-bounds template to be rejected: \(entry)")
            } catch LocalFirstError.unsupportedTemplate {
            } catch {
                Issue.record("Unexpected error for \(entry): \(error)")
            }
        }
    }

    @Test func monthlyLimitAcceptsAnObservedRetainedAnchor() throws {
        let entries = try engine.decodeSupportedEntries(
            json: #"[{"directive":"template","type":"simple","monthly":10,"limit":{"amount":20,"period":"monthly","hold":false,"start":"2026-09-07"},"priority":0}]"#
        )
        #expect(entries?.count == 1)
    }

    @Test func ancientDailyRecurrenceIsCalculatedArithmetically() throws {
        let decoded = try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "periodic",
                  "amount": 1,
                  "period": {"period": "day", "amount": 1},
                  "starting": "0001-01-01",
                  "priority": 0
                }]
                """
        )
        let entries = try #require(decoded)

        #expect(try engine.periodicAmount(entries[0], monthValue: 202607) == 3_100)
    }

    @Test func calculationUsesPreparedHistoryWithoutDatabaseAccess() throws {
        let decodedCapped = try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "simple",
                  "monthly": 50,
                  "limit": {
                    "amount": 100,
                    "period": "monthly",
                    "hold": false,
                    "start": null
                  },
                  "priority": 0
                }]
                """
        )
        let cappedEntries = try #require(decodedCapped)
        let decodedCopy = try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "copy",
                  "lookBack": 2,
                  "priority": 0
                }]
                """
        )
        let copyEntries = try #require(decodedCopy)

        let writes = try engine.computeWrites(
            categories: [
                "capped": .init(
                    entries: cappedEntries,
                    fromLastMonth: 7_000,
                    copiedBudgetedByLookBack: [:]
                ),
                "copy": .init(
                    entries: copyEntries,
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [2: 12_345]
                )
            ],
            orderedCategoryIDs: ["capped", "copy"],
            monthValue: 202607,
            availableBudget: 100_000
        )
        let amounts = Dictionary(uniqueKeysWithValues: writes.map { ($0.categoryID, $0.amount) })

        #expect(amounts["capped"] == 3_000)
        #expect(amounts["copy"] == 12_345)
    }

    @Test func hideFractionRoundsEachPriorityIncrementToWholeCurrencyUnits() throws {
        let hidden = BudgetTemplateEngine(
            currency: BudgetCurrency.catalog(code: "USD", hideFraction: true)
        )
        let visible = BudgetTemplateEngine()
        let decoded = try hidden.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "simple",
                  "monthly": 12.34,
                  "priority": 0
                }]
                """
        )
        let entries = try #require(decoded)

        #expect(
            try hidden.computeWrites(
                categories: [
                    "rounded": .init(
                        entries: entries,
                        fromLastMonth: 0,
                        copiedBudgetedByLookBack: [:]
                    )
                ],
                orderedCategoryIDs: ["rounded"],
            monthValue: 202607,
                availableBudget: 100_000
            ).map(\.amount) == [1_200]
        )
        #expect(
            try visible.computeWrites(
                categories: [
                    "exact": .init(
                        entries: entries,
                        fromLastMonth: 0,
                        copiedBudgetedByLookBack: [:]
                    )
                ],
                orderedCategoryIDs: ["exact"],
            monthValue: 202607,
                availableBudget: 100_000
            ).map(\.amount) == [1_234]
        )
    }

    @Test func hideFractionRoundsHalfAwayFromZeroThenAvailableClampStillApplies() throws {
        let engine = BudgetTemplateEngine(
            currency: BudgetCurrency.catalog(code: "USD", hideFraction: true)
        )
        let decoded = try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "simple",
                  "monthly": 12.50,
                  "priority": 1
                }]
                """
        )
        let entries = try #require(decoded)

        let unclamped = try engine.computeWrites(
            categories: [
                "half": .init(
                    entries: entries,
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [:]
                )
            ],
            orderedCategoryIDs: ["half"],
            monthValue: 202607,
            availableBudget: 100_000
        )
        #expect(unclamped.map(\.amount) == [1_300])

        let clamped = try engine.computeWrites(
            categories: [
                "half": .init(
                    entries: entries,
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [:]
                )
            ],
            orderedCategoryIDs: ["half"],
            monthValue: 202607,
            availableBudget: 1_250
        )
        #expect(clamped.map(\.amount) == [1_250])
    }

    @Test func hideFractionDoesNotRescaleZeroDecimalCurrencies() throws {
        let engine = BudgetTemplateEngine(
            currency: BudgetCurrency.catalog(code: "JPY", hideFraction: true)
        )
        let decoded = try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "simple",
                  "monthly": 1234,
                  "priority": 0
                }]
                """
        )
        let entries = try #require(decoded)
        let writes = try engine.computeWrites(
            categories: [
                "yen": .init(
                    entries: entries,
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [:]
                )
            ],
            orderedCategoryIDs: ["yen"],
            monthValue: 202607,
            availableBudget: 100_000
        )
        #expect(writes.map(\.amount) == [1_234])
    }

    @Test func remainderSplitsLeftoverAvailableByWeight() throws {
        let first = try #require(try engine.decodeSupportedEntries(
            json: #"[{"directive":"template","type":"remainder","weight":1}]"#
        ))
        let second = try #require(try engine.decodeSupportedEntries(
            json: #"[{"directive":"template","type":"remainder","weight":2}]"#
        ))

        let writes = try engine.computeWrites(
            categories: [
                "a": .init(entries: first, fromLastMonth: 0, copiedBudgetedByLookBack: [:]),
                "b": .init(entries: second, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["a", "b"],
            monthValue: 202607,
            availableBudget: 30_000
        )
        let amounts = Dictionary(uniqueKeysWithValues: writes.map { ($0.categoryID, $0.amount) })

        #expect(amounts["a"] == 10_000)
        #expect(amounts["b"] == 20_000)
    }

    @Test func remainderRejectsMissingWeight() throws {
        #expect(throws: LocalFirstError.self) {
            _ = try engine.decodeSupportedEntries(
                json: #"[{"directive":"template","type":"remainder"}]"#
            )
        }
    }

    @Test func remainderHideFractionAbsorbsLeftoverWholeUnits() throws {
        let hidden = BudgetTemplateEngine(
            currency: BudgetCurrency.catalog(code: "USD", hideFraction: true)
        )
        let first = try #require(try hidden.decodeSupportedEntries(
            json: #"[{"directive":"template","type":"remainder","weight":1}]"#
        ))
        let second = try #require(try hidden.decodeSupportedEntries(
            json: #"[{"directive":"template","type":"remainder","weight":1}]"#
        ))

        let writes = try hidden.computeWrites(
            categories: [
                "a": .init(entries: first, fromLastMonth: 0, copiedBudgetedByLookBack: [:]),
                "b": .init(entries: second, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["a", "b"],
            monthValue: 202607,
            availableBudget: 10_050
        )
        let amounts = Dictionary(uniqueKeysWithValues: writes.map { ($0.categoryID, $0.amount) })

        #expect(amounts["a"] == 5_000)
        #expect(amounts["b"] == 5_050)
    }

    @Test func remainderRedistributesAfterACategoryHitsItsLimit() throws {
        let limited = try #require(try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "remainder",
                  "weight": 1,
                  "limit": {"amount": 10, "period": "monthly", "hold": false, "start": null}
                }]
                """
        ))
        let open = try #require(try engine.decodeSupportedEntries(
            json: #"[{"directive":"template","type":"remainder","weight":1}]"#
        ))

        let writes = try engine.computeWrites(
            categories: [
                "capped": .init(entries: limited, fromLastMonth: 0, copiedBudgetedByLookBack: [:]),
                "open": .init(entries: open, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["capped", "open"],
            monthValue: 202607,
            availableBudget: 10_000
        )
        let amounts = Dictionary(uniqueKeysWithValues: writes.map { ($0.categoryID, $0.amount) })

        #expect(amounts["capped"] == 1_000)
        #expect(amounts["open"] == 9_000)
    }

    @Test func dailyLimitScalesByDaysInTheMonth() throws {
        let decoded = try #require(try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "simple",
                  "monthly": 100,
                  "limit": {"amount": 1, "period": "daily", "hold": false},
                  "priority": 0
                }]
                """
        ))

        let july = try engine.computeWrites(
            categories: [
                "daily": .init(entries: decoded, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["daily"],
            monthValue: 202607,
            availableBudget: 100_000
        )
        let february = try engine.computeWrites(
            categories: [
                "daily": .init(entries: decoded, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["daily"],
            monthValue: 202602,
            availableBudget: 100_000
        )

        #expect(july.map(\.amount) == [3_100])
        #expect(february.map(\.amount) == [2_800])
    }

    @Test func weeklyLimitCountsOccurrencesFromTheStartDate() throws {
        let decoded = try #require(try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "simple",
                  "monthly": 1000,
                  "limit": {
                    "amount": 10,
                    "period": "weekly",
                    "hold": false,
                    "start": "2026-07-03"
                  },
                  "priority": 0
                }]
                """
        ))

        let writes = try engine.computeWrites(
            categories: [
                "weekly": .init(entries: decoded, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["weekly"],
            monthValue: 202607,
            availableBudget: 100_000
        )

        #expect(writes.map(\.amount) == [5_000])
    }

    @Test func weeklyLimitWalksForwardFromAPriorStartDate() throws {
        let decoded = try #require(try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "simple",
                  "monthly": 1000,
                  "limit": {
                    "amount": 10,
                    "period": "weekly",
                    "hold": false,
                    "start": "2026-06-20"
                  },
                  "priority": 0
                }]
                """
        ))

        let writes = try engine.computeWrites(
            categories: [
                "weekly": .init(entries: decoded, fromLastMonth: 0, copiedBudgetedByLookBack: [:])
            ],
            orderedCategoryIDs: ["weekly"],
            monthValue: 202607,
            availableBudget: 100_000
        )

        // June 20 + 2 weeks = July 4, then 11, 18, 25. Four weeks in July.
        #expect(writes.map(\.amount) == [4_000])
    }

    @Test func weeklyLimitWithoutAStartDateIsRejected() throws {
        #expect(throws: LocalFirstError.self) {
            _ = try engine.decodeSupportedEntries(
                json: """
                    [{
                      "directive": "template",
                      "type": "limit",
                      "amount": 10,
                      "period": "weekly",
                      "hold": false
                    }]
                    """
            )
        }
    }

    @Test func priorityTemplatesClampToAvailableBudget() throws {
        let decoded = try #require(try engine.decodeSupportedEntries(
            json: #"[{"directive":"template","type":"simple","monthly":50,"priority":1}]"#
        ))
        let categories = [
            "later": BudgetTemplateEngine.Category(
                entries: decoded,
                fromLastMonth: 0,
                copiedBudgetedByLookBack: [:]
            )
        ]

        let writes = try engine.computeWrites(
            categories: categories,
            orderedCategoryIDs: ["later"],
            monthValue: 202607,
            availableBudget: 2_000
        )

        #expect(writes.map(\.amount) == [2_000])
    }

    @Test func amountToMinorUnitsMatchesJavaScriptMathRoundOnExactHalves() throws {
        // 1.125 and -1.125 are binary-exact. * 100 yields ±112.5.
        // JS Math.round(112.5) == 113; Math.round(-112.5) == -112.
        #expect(try engine.amountToMinorUnits(1.125) == 113)
        #expect(try engine.amountToMinorUnits(-1.125) == -112)
    }

    @Test func hideFractionMatchesJavaScriptMathRoundOnNegativeHalves() throws {
        let hidden = BudgetTemplateEngine(
            currency: BudgetCurrency.catalog(code: "USD", hideFraction: true)
        )
        #expect(try hidden.removeFractionLikeActual(150) == 200)
        #expect(try hidden.removeFractionLikeActual(-150) == -100)
    }

    @Test func targetValidationRejectsAnExpiredNonRepeatingMonth() throws {
        let decoded = try engine.decodeSupportedEntries(
            json: """
                [{
                  "directive": "template",
                  "type": "by",
                  "amount": 120,
                  "month": "2026-06",
                  "priority": 0
                }]
                """
        )
        let entries = try #require(decoded)

        #expect(throws: LocalFirstError.self) {
            try engine.validate(entries, for: 202607)
        }
    }
}
