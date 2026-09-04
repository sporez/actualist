import Foundation
import Testing
@testable import Actualist

@Suite("Budget template editor codec")
struct BudgetTemplateEditorCodecTests {
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!

    @Test func notesRoundTripPerEntryAndWhitespaceOnlyNotesAreOmitted() throws {
        let json = """
            [
              {"directive":"template","type":"periodic","amount":400,"period":{"period":"month","amount":1},"starting":"2026-09-01","priority":1,"description":"First line\\nSecond line — café"},
              {"directive":"template","type":"remainder","weight":1,"priority":null,"description":"  \\n  "},
              {"directive":"goal","type":"goal","amount":500,"description":"Goal note"}
            ]
            """
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts.count == 3)
        #expect(drafts[0].description == "First line\nSecond line — café")
        #expect(drafts[1].description == nil)
        #expect(drafts[2].description == "Goal note")

        let encoded = try BudgetTemplateDefinition.encode(drafts)
        let reopened = try #require(BudgetTemplateDefinition.drafts(fromJSON: encoded, now: now))
        #expect(reopened == drafts)
        #expect(!encoded.contains(#""description":"  "#))
    }

    @Test func unknownFieldLocksBeforeTheMathDecoderDropsIt() {
        let json = #"[{"directive":"template","type":"simple","monthly":400,"priority":1,"futureField":true}]"#
        #expect(BudgetTemplateDefinition.drafts(fromJSON: json, now: now) == nil)
        #expect(!BudgetTemplateDefinition.isEditorEditableJSON(json, now: now))
        #expect(
            BudgetTemplateEditorCodec.decodeEditor(json: json, now: now)
                == .failure(.unsupportedField("simple.futureField"))
        )
    }

    @Test func unknownNestedFieldsAndIncompleteLimitsDoNotGetDefaulted() {
        let periodJSON = #"[{"directive":"template","type":"periodic","amount":400,"period":{"period":"month","amount":1,"future":true},"priority":1}]"#
        #expect(
            BudgetTemplateEditorCodec.decodeEditor(json: periodJSON, now: now)
                == .failure(.unsupportedField("periodic.period.future"))
        )

        let limitJSON = #"[{"directive":"template","type":"simple","monthly":400,"priority":1,"limit":{"hold":false,"period":"monthly"}}]"#
        #expect(BudgetTemplateDefinition.drafts(fromJSON: limitJSON, now: now) == nil)
    }

    @Test func phase5ModifiersStayEditableUntilTheirValuesAreRepaired() throws {
        let json = """
            [{"directive":"template","type":"schedule","name":"Rent","full":true,"adjustment":-100,"adjustmentType":"percent","priority":1},
            {"directive":"template","type":"average","numMonths":3,"adjustment":1001,"adjustmentType":"percent","priority":1}
            ]
            """
        #expect(BudgetTemplateDefinition.isEditorEditableJSON(json, now: now))
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts.count == 2)
        let encoded = try BudgetTemplateDefinition.encode(drafts)
        #expect(encoded.contains(#""full":true"#))
        #expect(encoded.contains(#""adjustment":-100"#))
        #expect(encoded.contains(#""adjustmentType":"percent""#))
        #expect(try BudgetTemplateDefinition.drafts(fromJSON: encoded, now: now) == drafts)
        #expect(
            BudgetTemplateAuthoringValidation.issues(
                for: drafts,
                context: BudgetTemplateAuthoringContext(today: now)
            ).contains(.invalidEntry(index: 0))
        )
        #expect(
            BudgetTemplateAuthoringValidation.issues(
                for: drafts,
                context: BudgetTemplateAuthoringContext(today: now)
            ).contains(.invalidEntry(index: 1))
        )
    }

    @Test func monthlyLimitRetainsValidWeeklyAnchorForActualCompatibility() throws {
        let json = #"[{"directive":"template","type":"simple","monthly":400,"priority":1,"limit":{"amount":500,"hold":false,"period":"monthly","start":"2026-09-07"}}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        guard case .balanceLimit(let limit) = drafts[1] else {
            Issue.record("Expected a standalone limit draft")
            return
        }
        #expect(limit.start == "2026-09-07")
        #expect(BudgetTemplateDefinition.isEditorEditableJSON(json, now: now))
    }

    @Test func normalizedCatalogCoversLegacyAndCutBShapes() throws {
        let json = """
            [
              {"directive":"template","type":"simple","limit":{"amount":500,"hold":false,"period":"monthly"},"priority":1,"description":"Cap note"},
              {"directive":"template","type":"periodic","amount":50,"period":{"period":"week","amount":2},"starting":"2026-09-01","priority":2,"limit":{"amount":500,"hold":true,"period":"weekly","start":"2026-09-01"}},
              {"directive":"template","type":"by","amount":1200,"month":"2027-09","annual":true,"priority":1},
              {"directive":"template","type":"by","amount":1200,"month":"2027-10","from":"2027-08","priority":1},
              {"directive":"template","type":"spend","amount":300,"month":"2026-09","from":"2026-07","priority":1},
              {"directive":"template","type":"percentage","percent":10,"previous":true,"category":"Salary","priority":1},
              {"directive":"template","type":"limit","amount":500,"period":"daily","hold":false,"priority":null},
              {"directive":"template","type":"refill","priority":1},
              {"directive":"template","type":"schedule","name":"Rent","scheduleId":"rent","full":true,"adjustment":10,"adjustmentType":"percent","priority":1},
              {"directive":"template","type":"average","numMonths":3,"adjustment":10,"adjustmentType":"fixed","priority":1},
              {"directive":"template","type":"copy","lookBack":1,"priority":1,"limit":{"amount":100,"hold":false,"period":"monthly"}},
              {"directive":"template","type":"remainder","weight":1,"priority":null,"limit":{"amount":250,"hold":true,"period":"monthly"}},
              {"directive":"goal","type":"goal","amount":1000}
            ]
            """
        let drafts = try BudgetTemplateDefinition.normalizedDrafts(fromJSON: json, now: now)
        #expect(drafts.count == 16)
        #expect(drafts.contains { if case .refill = $0 { true } else { false } })
        #expect(drafts.contains { if case .balanceLimit = $0 { true } else { false } })
        #expect(drafts.contains { if case .dateTarget(let value) = $0 {
            return value.repeatInterval == 1 && value.annual && !value.isSpend
        } else { return false } })
        #expect(drafts.contains { if case .dateTarget(let value) = $0 {
            return value.isSpend && value.fromMonth == "2026-07"
        } else { return false } })
        #expect(drafts.contains { if case .dateTarget(let value) = $0 {
            return !value.isSpend && value.fromMonth == "2027-08"
        } else { return false } })
        let legacyBy = drafts.first { draft in
            if case .dateTarget(let value) = draft {
                return !value.isSpend && value.fromMonth == "2027-08"
            }
            return false
        }
        let legacyByJSON = try BudgetTemplateDefinition.encode([try #require(legacyBy)])
        #expect(legacyByJSON.contains(#""type":"by""#))
        #expect(legacyByJSON.contains(#""from":"2027-08""#))
        #expect(drafts.contains { if case .schedule(let value) = $0 {
            return value.full && value.adjustment == .percent(10)
        } else { return false } })
        #expect(drafts.contains { if case .average(let value) = $0 {
            return value.adjustment == .fixed(10)
        } else { return false } })
        #expect(drafts.contains { if case .copy(let value) = $0 {
            return value.legacyLimit?.amount == 100
        } else { return false } })
        #expect(drafts.filter { if case .remainder = $0 { true } else { false } }.count == 1)
        #expect(drafts.filter { if case .goal = $0 { true } else { false } }.count == 1)
    }

    @Test func authoringValidationUsesPickerContextAndListRules() {
        let context = BudgetTemplateAuthoringContext(
            today: now,
            schedules: [BudgetTemplateScheduleOption(id: "rent", name: "Rent")],
            incomeCategories: [BudgetTemplateIncomeOption(id: "salary", name: "Salary")]
        )
        let drafts: [BudgetTemplateDraft] = [
            .schedule(name: "Rent", scheduleId: "rent"),
            .percentage(percent: 60, sourceCategory: "Salary"),
            .percentage(percent: 50, sourceCategory: "salary")
        ]
        let issues = BudgetTemplateAuthoringValidation.issues(for: drafts, context: context)
        #expect(issues.contains(.percentageConflict(previous: false, source: "salary")))
        #expect(!issues.contains { if case .scheduleNotFound = $0 { true } else { false } })
    }

    @Test func defaultsAndListRulesMatchThePinnedEditorContract() {
        let target = BudgetTemplateDraft.dateTarget(now: now)
        guard case .dateTarget(let value) = target else {
            Issue.record("Expected a date-target draft")
            return
        }
        #expect(value.month == "2027-09")
        #expect(value.repeatInterval == 1)
        #expect(value.annual)

        let context = BudgetTemplateAuthoringContext(today: now)
        let invalid = [
            BudgetTemplateDraft.percentage(sourceCategory: "available funds", previous: true),
            BudgetTemplateDraft.dateTarget(fromMonth: "2026-08", isSpend: true),
            BudgetTemplateDraft.dateTarget(fromMonth: "2026-09", isSpend: true)
        ]
        let issues = BudgetTemplateAuthoringValidation.issues(for: invalid, context: context)
        #expect(issues.contains(.percentageSourceNotFound(index: 0)))
        #expect(issues.contains(.duplicateSpend))
    }
}
