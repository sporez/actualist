import Testing
@testable import Actualist

@Suite("Budget template engine")
struct BudgetTemplateEngineTests {
    private let engine = BudgetTemplateEngine()

    @Test func rejectsEveryBoundedFieldBeforeCalculation() throws {
        let invalidEntries = [
            #"{"directive":"template","type":"simple","monthly":1000000001,"priority":0}"#,
            #"{"directive":"template","type":"simple","monthly":-1,"priority":0}"#,
            #"{"directive":"template","type":"simple","monthly":10,"percentage":101,"priority":0}"#,
            #"{"directive":"template","type":"periodic","amount":1,"period":{"period":"day","amount":1201},"starting":"2026-07-01","priority":0}"#,
            #"{"directive":"template","type":"copy","lookBack":1201,"priority":0}"#,
            #"{"directive":"template","type":"by","amount":10,"month":"2026-08","repeat":1201,"priority":0}"#,
            #"{"directive":"template","type":"simple","monthly":10,"priority":1001}"#
        ]

        for entry in invalidEntries {
            do {
                _ = try engine.decodeSupportedEntries(json: "[\(entry)]")
                Issue.record("Expected the out-of-bounds template to be rejected: \(entry)")
            } catch LocalFirstError.unsupportedTemplate {
                // Expected.
            } catch {
                Issue.record("Unexpected error for \(entry): \(error)")
            }
        }
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
            monthValue: 202607,
            availableBudget: 100_000
        )
        let amounts = Dictionary(uniqueKeysWithValues: writes.map { ($0.categoryID, $0.amount) })

        #expect(amounts["capped"] == 3_000)
        #expect(amounts["copy"] == 12_345)
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
