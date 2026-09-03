import Foundation
import Testing
@testable import Actualist

@Suite("Budget template definition")
struct BudgetTemplateDefinitionTests {
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!
    private let engine = BudgetTemplateEngine()

    // MARK: - Cut A JSON round-trip

    @Test func roundTrip_monthlyPeriodic() throws {
        let json = """
            [{"directive":"template","type":"periodic","amount":400,"period":{"period":"month","amount":1},"starting":"2026-04-01","priority":1}]
            """
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [
            .monthlyFixed(
                BudgetTemplateDraft.MonthlyFixed(
                    amount: 400,
                    priority: 1,
                    starting: "2026-04-01",
                    upTo: nil
                )
            )
        ])
        try assertEngineAccepts(drafts, amount: 400)
    }

    @Test func roundTrip_monthlyPeriodicWithHold() throws {
        let json = """
            [{"directive":"template","type":"periodic","amount":20,"period":{"period":"month","amount":1},"starting":"2026-02-01","priority":11,"limit":{"amount":200,"hold":true,"period":"monthly"}}]
            """
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [
            .monthlyFixed(
                BudgetTemplateDraft.MonthlyFixed(
                    amount: 20,
                    priority: 11,
                    starting: "2026-02-01",
                    upTo: BudgetTemplateUpToHold(
                        amount: 200,
                        hold: true,
                        period: "monthly",
                        start: nil
                    )
                )
            )
        ])
        try assertEngineAccepts(drafts)
    }

    @Test func roundTrip_copy() throws {
        let json = #"[{"directive":"template","type":"copy","lookBack":1,"priority":0}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [.copy(lookBack: 1, priority: 0)])
        try assertEngineAccepts(drafts)
    }

    @Test func roundTrip_averageWithoutAdjustment() throws {
        let json = #"[{"directive":"template","type":"average","numMonths":3,"priority":1}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [.average(numMonths: 3, priority: 1)])
        try assertEngineAccepts(drafts)
    }

    @Test func roundTrip_scheduleByIdAndName() throws {
        let json = #"[{"directive":"template","type":"schedule","name":"Rent","scheduleId":"sch-1","priority":1}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [.schedule(name: "Rent", scheduleId: "sch-1", priority: 1)])
        let encoded = try BudgetTemplateDefinition.encode(drafts)
        let entries = try #require(try engine.decodeSupportedEntries(json: encoded))
        #expect(entries[0].presentScheduleID == "sch-1")
        #expect(entries[0].trimmedScheduleName == "Rent")
        #expect(entries[0].full == nil)
    }

    @Test func roundTrip_remainderWithoutNestedLimit() throws {
        let json = #"[{"directive":"template","type":"remainder","weight":2,"priority":null}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [.remainder(weight: 2)])
        let encoded = try BudgetTemplateDefinition.encode(drafts)
        #expect(encoded.contains(#""priority":null"#))
        try assertEngineAccepts(drafts)
    }

    @Test func roundTrip_goal() throws {
        let json = #"[{"directive":"goal","type":"goal","amount":500,"priority":null}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [.goal(amount: 500)])
        let encoded = try BudgetTemplateDefinition.encode(drafts)
        #expect(encoded.contains(#""priority":null"#))
        try assertEngineAccepts(drafts)
    }

    @Test func roundTrip_multiTemplateCategory() throws {
        let json = """
            [
              {"directive":"template","type":"simple","monthly":400,"priority":1},
              {"directive":"template","type":"remainder","weight":1,"priority":null}
            ]
            """
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts.count == 2)
        #expect(drafts[1] == .remainder(weight: 1))
        try assertEngineAccepts(drafts)
    }

    // MARK: - simple → periodic save encoding

    @Test func simpleSaveEncoding_emitsMonthlyPeriodicForCurrentMonth() throws {
        let json = #"[{"directive":"template","type":"simple","monthly":45,"priority":3}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [
            .monthlyFixed(amount: 45, priority: 3, now: now)
        ])
        let encoded = try BudgetTemplateDefinition.encode(drafts)
        #expect(!encoded.contains("\"type\":\"simple\""))
        let entries = try #require(try engine.decodeSupportedEntries(json: encoded))
        #expect(entries[0].type == "periodic")
        #expect(entries[0].amount == 45)
        #expect(entries[0].period?.period == "month")
        #expect(entries[0].period?.amount == 1)
        #expect(entries[0].starting == "2026-09-01")
        #expect(entries[0].priority == 3)
    }

    @Test func simpleSaveEncoding_preservesNestedUpTo() throws {
        let json = """
            [{"directive":"template","type":"simple","monthly":20,"priority":11,"limit":{"amount":200,"hold":false,"period":"monthly"}}]
            """
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        let encoded = try BudgetTemplateDefinition.encode(drafts)
        let entries = try #require(try engine.decodeSupportedEntries(json: encoded))
        #expect(entries.count == 1)
        #expect(entries[0].type == "periodic")
        #expect(entries[0].amount == 20)
        #expect(entries[0].limit?.amount == 200)
        #expect(entries[0].limit?.hold == false)
        #expect(entries[0].limit?.period == "monthly")
    }

    @Test func newMonthlyFixed_usesDefaultPriorityAndFirstOfMonth() throws {
        let drafts = [BudgetTemplateDraft.monthlyFixed(now: now)]
        let encoded = try BudgetTemplateDefinition.encode(drafts)
        let entries = try #require(try engine.decodeSupportedEntries(json: encoded))
        #expect(entries[0].priority == 1)
        #expect(entries[0].starting == "2026-09-01")
        #expect(entries[0].amount == 100)
    }

    // MARK: - Lock matrix

    @Test func lock_uiManagedCutAIsEditable() {
        let json = #"[{"directive":"template","type":"simple","monthly":400,"priority":1}]"#
        #expect(
            lock(source: "ui", json: json) == .editable
        )
    }

    @Test func lock_emptyListIsEditable() {
        #expect(lock(source: "ui", json: nil) == .editable)
        #expect(lock(source: "ui", json: "[]") == .editable)
        #expect(lock(source: "ui", json: "null") == .editable)
    }

    @Test func lock_noteManagedIsReadOnly() {
        let json = #"[{"directive":"template","type":"simple","monthly":400,"priority":1}]"#
        #expect(lock(source: "note", json: json) == .readOnly(.noteManaged))
        #expect(lock(source: "notes", json: json) == .readOnly(.noteManaged))
        #expect(
            lock(source: nil, noteHasDirectives: true, json: json) == .readOnly(.noteManaged)
        )
        #expect(
            lock(source: "note", json: json).testerFacingReason?.contains("category note") == true
        )
    }

    @Test func lock_staleNotesTakesPrecedenceOverNoteManaged() {
        let json = #"[{"directive":"template","type":"simple","monthly":400,"priority":1}]"#
        #expect(
            lock(source: "note", isStale: true, json: json) == .readOnly(.staleNotes)
        )
    }

    @Test func lock_uiSourceIgnoresStaleAndNoteDirectives() {
        let json = #"[{"directive":"template","type":"simple","monthly":400,"priority":1}]"#
        #expect(
            lock(
                source: "ui",
                noteHasDirectives: true,
                isStale: true,
                json: json
            ) == .editable
        )
    }

    @Test func lock_missingColumnsFailClosed() {
        let json = #"[{"directive":"template","type":"simple","monthly":400,"priority":1}]"#
        #expect(
            lock(hasGoalDefColumn: false, json: json) == .readOnly(.missingColumns)
        )
        #expect(
            lock(hasTemplateSettingsColumn: false, json: json) == .readOnly(.missingColumns)
        )
        #expect(
            lock(hasGoalDefColumn: false, source: "ui", json: nil) == .readOnly(.missingColumns)
        )
    }

    @Test func lock_missingColumnsWinsOverNoteManaged() {
        #expect(
            lock(
                hasTemplateSettingsColumn: false,
                source: "note",
                isStale: true,
                json: "not-json"
            ) == .readOnly(.missingColumns)
        )
    }

    @Test func lock_unreadableJSONIsUnsupported() {
        #expect(lock(source: "ui", json: "{") == .readOnly(.unsupportedType))
        #expect(lock(source: "ui", json: "{}") == .readOnly(.unsupportedType))
    }

    @Test func lock_anyUnsupportedTypeLocksTheCategory() {
        let mixed = """
            [
              {"directive":"template","type":"simple","monthly":400,"priority":1},
              {"directive":"template","type":"percentage","percent":10,"previous":false,"category":"all income","priority":0}
            ]
            """
        #expect(lock(source: "ui", json: mixed) == .readOnly(.unsupportedType))
        #expect(BudgetTemplateDefinition.drafts(fromJSON: mixed, now: now) == nil)
    }

    @Test(arguments: [
        #"[{"directive":"template","type":"by","amount":1200,"month":"2027-09","priority":1}]"#,
        #"[{"directive":"template","type":"spend","amount":300,"month":"2026-09","from":"2026-07","priority":0}]"#,
        #"[{"directive":"template","type":"percentage","percent":10,"previous":false,"category":"all income","priority":0}]"#,
        #"[{"directive":"template","type":"limit","amount":500,"period":"monthly","hold":false,"priority":null}]"#,
        #"[{"directive":"template","type":"refill","priority":1}]"#,
        #"[{"directive":"template","type":"periodic","amount":1,"period":{"period":"day","amount":1},"starting":"2026-01-01","priority":0}]"#,
        #"[{"directive":"template","type":"periodic","amount":50,"period":{"period":"month","amount":2},"starting":"2026-01-01","priority":0}]"#,
        #"[{"directive":"template","type":"schedule","name":"Rent","full":true,"priority":1}]"#,
        #"[{"directive":"template","type":"schedule","name":"Rent","adjustment":10,"adjustmentType":"percent","priority":1}]"#,
        #"[{"directive":"template","type":"average","numMonths":3,"adjustment":5,"adjustmentType":"percent","priority":1}]"#,
        #"[{"directive":"template","type":"remainder","weight":1,"priority":null,"limit":{"amount":500,"hold":true,"period":"monthly"}}]"#,
        #"[{"directive":"template","type":"copy","lookBack":1,"priority":0,"limit":{"amount":100,"hold":false,"period":"monthly"}}]"#,
        ##"[{"directive":"error","type":"error","line":"#template bad","error":"parse failure"}]"##,
        #"[{"directive":"template","type":"simple","priority":1,"limit":{"amount":1000,"hold":false,"period":"monthly"}}]"#
    ])
    func lock_cutBAndInvalidTypes(json: String) {
        #expect(lock(source: "ui", json: json) == .readOnly(.unsupportedType))
        #expect(BudgetTemplateDefinition.drafts(fromJSON: json, now: now) == nil)
    }

    @Test func lock_scheduleWithoutFullOrAdjustmentIsEditable() {
        let json = #"[{"directive":"template","type":"schedule","name":"Rent","priority":1}]"#
        #expect(lock(source: "ui", json: json) == .editable)
    }

    // MARK: - Summaries

    @Test func summary_monthlyAndRemainder() {
        let drafts: [BudgetTemplateDraft] = [
            .monthlyFixed(amount: 400, now: now),
            .remainder()
        ]
        let line = BudgetTemplateSummary.line(
            drafts: drafts,
            currency: .usd,
            randomized: false,
            seed: "groceries"
        )
        let amount = BudgetCurrency.usd.formatted(40_000)
        #expect(line == "\(amount)/mo · Remainder")
    }

    @Test func summary_upToAndHoldAndGoalAndHistory() {
        let upTo = BudgetTemplateDraft.monthlyFixed(
            amount: 20,
            now: now,
            upTo: BudgetTemplateUpToHold(amount: 200, hold: false, period: "monthly", start: nil)
        )
        let hold = BudgetTemplateDraft.monthlyFixed(
            amount: 50,
            now: now,
            upTo: BudgetTemplateUpToHold(amount: 1_000, hold: true, period: "monthly", start: nil)
        )
        let currency = BudgetCurrency.usd
        #expect(
            BudgetTemplateSummary.line(
                drafts: [upTo],
                currency: currency,
                randomized: false,
                seed: "a"
            ) == "\(currency.formatted(2_000))/mo up to \(currency.formatted(20_000))"
        )
        #expect(
            BudgetTemplateSummary.line(
                drafts: [hold],
                currency: currency,
                randomized: false,
                seed: "b"
            ) == "\(currency.formatted(5_000))/mo hold \(currency.formatted(100_000))"
        )
        #expect(
            BudgetTemplateSummary.line(
                drafts: [.copy(lookBack: 1), .copy(lookBack: 3), .average(numMonths: 6), .goal(amount: 500)],
                currency: currency,
                randomized: false,
                seed: "c"
            ) == "Copy last month · Copy 3 months ago · 6-month average · Goal \(currency.formatted(50_000))"
        )
        #expect(
            BudgetTemplateSummary.line(
                drafts: [.schedule(name: "Rent"), .schedule(name: "")],
                currency: currency,
                randomized: false,
                seed: "d"
            ) == "Rent · Schedule"
        )
        #expect(
            BudgetTemplateSummary.line(
                drafts: [],
                currency: currency,
                randomized: false,
                seed: "e"
            ) == ""
        )
    }

    @Test func summary_privacyDoesNotLeakRealAmounts() {
        let drafts = [BudgetTemplateDraft.monthlyFixed(amount: 400, now: now)]
        let real = BudgetCurrency.usd.formatted(40_000)
        let line = BudgetTemplateSummary.line(
            drafts: drafts,
            currency: .usd,
            randomized: true,
            seed: "groceries"
        )
        let expected = PrivacyDisplay.money(40_000, seed: "groceries-0", currency: .usd)
        #expect(line == "\(expected)/mo")
        #expect(line.contains(expected))
        if real != expected {
            #expect(!line.contains(real))
        }
    }

    // MARK: - Helpers

    private func lock(
        hasGoalDefColumn: Bool = true,
        hasTemplateSettingsColumn: Bool = true,
        source: String? = "ui",
        noteHasDirectives: Bool = false,
        isStale: Bool = false,
        json: String?
    ) -> BudgetTemplateCategoryLock {
        BudgetTemplateCategoryLock.evaluate(
            hasGoalDefColumn: hasGoalDefColumn,
            hasTemplateSettingsColumn: hasTemplateSettingsColumn,
            source: source,
            noteHasDirectives: noteHasDirectives,
            isStale: isStale,
            goalDefJSON: json
        )
    }

    private func assertEngineAccepts(
        _ drafts: [BudgetTemplateDraft],
        amount: Double? = nil
    ) throws {
        let encoded = try BudgetTemplateDefinition.encode(drafts)
        let entries = try #require(try engine.decodeSupportedEntries(json: encoded))
        #expect(entries.count == drafts.count)
        if let amount {
            #expect(entries[0].amount == amount)
        }
        let reloaded = try #require(BudgetTemplateDefinition.drafts(fromJSON: encoded, now: now))
        #expect(reloaded == drafts)
    }
}
