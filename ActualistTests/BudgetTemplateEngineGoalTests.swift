import Foundation
import Testing
@testable import Actualist

struct BudgetTemplateEngineGoalTests {
    private let engine = BudgetTemplateEngine()

    @Test func goalOnlyKeepsPreviouslyBudgetedAndSetsLongGoal() throws {
        let writes = try engine.computeWrites(
            categories: [
                "food": .init(
                    entries: try #require(try engine.decodeSupportedEntries(
                        json: #"[{"directive":"goal","type":"goal","amount":500,"priority":null}]"#
                    )),
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [:],
                    previouslyBudgeted: 12_345
                )
            ],
            orderedCategoryIDs: ["food"],
            monthValue: 202607,
            availableBudget: 100_000
        )
        let write = try #require(writes.first)
        #expect(write.categoryID == "food")
        #expect(write.amount == 12_345)
        #expect(write.goal == 50_000)
        #expect(write.longGoal == 1)
    }

    @Test func mixedGoalAndSimpleWritesBudgetAndLongGoal() throws {
        let writes = try engine.computeWrites(
            categories: [
                "food": .init(
                    entries: try #require(try engine.decodeSupportedEntries(
                        json: """
                            [
                              {"directive":"goal","type":"goal","amount":500,"priority":null},
                              {"directive":"template","type":"simple","monthly":50,"priority":0}
                            ]
                            """
                    )),
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [:],
                    previouslyBudgeted: 8_000
                )
            ],
            orderedCategoryIDs: ["food"],
            monthValue: 202607,
            availableBudget: 100_000
        )
        let write = try #require(writes.first)
        #expect(write.amount == 5_000)
        #expect(write.goal == 50_000)
        #expect(write.longGoal == 1)
    }

    @Test func nonGoalTemplateReportsUnclampedFullAmountAsGoal() throws {
        let writes = try engine.computeWrites(
            categories: [
                "food": .init(
                    entries: try #require(try engine.decodeSupportedEntries(
                        json: #"[{"directive":"template","type":"simple","monthly":80,"priority":1}]"#
                    )),
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [:]
                )
            ],
            orderedCategoryIDs: ["food"],
            monthValue: 202607,
            availableBudget: 2_500
        )
        let write = try #require(writes.first)
        #expect(write.amount == 2_500)
        #expect(write.goal == 8_000)
        #expect(write.longGoal == nil)
    }

    @Test func remainderDoesNotChangeReportedFullAmountGoal() throws {
        let writes = try engine.computeWrites(
            categories: [
                "food": .init(
                    entries: try #require(try engine.decodeSupportedEntries(
                        json: """
                            [
                              {"directive":"template","type":"simple","monthly":10,"priority":0},
                              {"directive":"template","type":"remainder","weight":1,"priority":null}
                            ]
                            """
                    )),
                    fromLastMonth: 0,
                    copiedBudgetedByLookBack: [:]
                )
            ],
            orderedCategoryIDs: ["food"],
            monthValue: 202607,
            availableBudget: 4_000
        )
        let write = try #require(writes.first)
        #expect(write.amount == 4_000)
        #expect(write.goal == 1_000)
        #expect(write.longGoal == nil)
    }

    @Test func goalPlusErrorDecodesTheGoal() throws {
        let decoded = try #require(
            try engine.decodeSupportedEntries(
                json: """
                    [
                      {"directive":"goal","type":"goal","amount":500,"priority":null},
                      {"directive":"error","type":"error","line":"#template bad","error":"parse failure"}
                    ]
                    """
            )
        )
        #expect(decoded.count == 1)
        #expect(decoded[0].isGoal)
    }
}
