import Foundation
import Testing
@testable import Actualist

@Suite("Budget template editor Phase 3")
struct BudgetTemplateEditorPhase3Tests {
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!

    @Test func fixedCadenceEncodesIntervalAndStartingDate() throws {
        var draft = BudgetTemplateDraft.monthlyFixed(amount: 125, now: now)
        guard case .monthlyFixed(var fixed) = draft else {
            Issue.record("Expected a fixed draft")
            return
        }
        fixed.cadence = .week
        fixed.interval = 2
        fixed.starting = "2026-02-28"
        draft = .monthlyFixed(fixed)

        let json = try BudgetTemplateDefinition.encode([draft])
        let entries = try #require(try BudgetTemplateEngine().decodeSupportedEntries(json: json))
        #expect(entries.count == 1)
        #expect(entries[0].type == "periodic")
        #expect(entries[0].amount == 125)
        #expect(entries[0].period?.period == "week")
        #expect(entries[0].period?.amount == 2)
        #expect(entries[0].starting == "2026-02-28")
    }

    @Test func fixedCadenceAndLegacyNestedCapNormalizeToSeparateRows() throws {
        let json = #"[{"directive":"template","type":"periodic","amount":125,"period":{"period":"day","amount":3},"starting":"2026-02-28","priority":2,"limit":{"amount":500,"hold":true,"period":"weekly","start":"2026-02-26"}}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts.count == 2)
        guard case .monthlyFixed(let fixed) = drafts[0],
              case .balanceLimit(let limit) = drafts[1] else {
            Issue.record("Expected fixed and standalone limit drafts")
            return
        }
        #expect(fixed.cadence == .day)
        #expect(fixed.interval == 3)
        #expect(fixed.starting == "2026-02-28")
        #expect(limit.amount == 500)
        #expect(limit.hold)
        #expect(limit.period == .weekly)
        #expect(limit.start == "2026-02-26")

        let encoded = try BudgetTemplateDefinition.encode(drafts)
        #expect(encoded.contains(#""type":"limit""#))
        #expect(!encoded.contains(#""limit":{"#))
    }

    @Test func limitOnlySimpleTemplateNormalizesToLimitAndRefill() throws {
        let json = #"[{"directive":"template","type":"simple","priority":4,"limit":{"amount":500,"hold":false,"period":"monthly"}}]"#
        let drafts = try #require(BudgetTemplateDefinition.drafts(fromJSON: json, now: now))
        #expect(drafts == [
            .balanceLimit(amount: 500, period: .monthly),
            .refill(priority: 4)
        ])
        #expect(BudgetTemplateDefinition.isEditorEditableJSON(json, now: now))
    }

    @Test func emptyLegacySimpleDoesNotBecomeEditable() {
        let json = #"[{"directive":"template","type":"simple","priority":1}]"#
        #expect(BudgetTemplateDefinition.drafts(fromJSON: json, now: now) == nil)
        #expect(!BudgetTemplateDefinition.isEditorEditableJSON(json, now: now))
    }

    @Test func balanceLimitEncodesHoldPeriodAndWeeklyAnchor() throws {
        let draft = BudgetTemplateDraft.balanceLimit(
            amount: 75,
            hold: true,
            period: .weekly,
            start: "2026-09-15"
        )
        let json = try BudgetTemplateDefinition.encode([draft])
        let entries = try #require(try BudgetTemplateEngine().decodeSupportedEntries(json: json))
        #expect(entries.count == 1)
        #expect(entries[0].type == "limit")
        #expect(entries[0].priority == nil)
        #expect(entries[0].standaloneLimit?.amount == 75)
        #expect(entries[0].standaloneLimit?.period == "weekly")
        #expect(entries[0].standaloneLimit?.hold == true)
        #expect(entries[0].standaloneLimit?.start == "2026-09-15")
    }

    @Test func refillValidationRequiresExactlyOneContributorAndLimit() {
        let context = BudgetTemplateAuthoringContext(today: now)
        let refillOnly = BudgetTemplateAuthoringValidation.issues(
            for: [.refill()],
            context: context
        )
        #expect(refillOnly.contains(.refillRequiresLimit))

        let limitAndRefill = BudgetTemplateAuthoringValidation.issues(
            for: [.balanceLimit(), .refill()],
            context: context
        )
        #expect(limitAndRefill.contains(.limitRequiresContributor))

        let valid = BudgetTemplateAuthoringValidation.issues(
            for: [.monthlyFixed(now: now), .balanceLimit(), .refill()],
            context: context
        )
        #expect(valid.isEmpty)
    }

    @Test func weeklyStartUsesEarliestFixedStartAndWeekdayChangesWithoutUTCDrift() {
        let start = BudgetTemplateEditorCalendar.defaultWeeklyStart(
            for: [.monthlyFixed(now: now)],
            now: now
        )
        #expect(start == "2026-09-01")
        #expect(
            BudgetTemplateEditorCalendar.defaultWeeklyStart(
                for: [.dateTarget(month: "2025-12")],
                now: now
            ) == "2025-12-01"
        )
        #expect(BudgetTemplateEditorCalendar.weekday(for: "2026-09-15") == 3)
        #expect(
            BudgetTemplateEditorCalendar.dayID("2026-09-15", movingToWeekday: 1)
                == "2026-09-13"
        )
    }

    @Test func fixedInputInterpreterOwnsIntervalAndLimitAmount() {
        let fixed = BudgetTemplateDraft.monthlyFixed(now: now)
        guard let updatedFixed = BudgetTemplateEditorInputInterpreter.applying(
            "3",
            for: .interval,
            to: fixed,
            currency: .usd
        ) else {
            Issue.record("Expected a valid interval")
            return
        }
        guard case .monthlyFixed(let fixedValue) = updatedFixed else {
            Issue.record("Expected a fixed draft")
            return
        }
        #expect(fixedValue.interval == 3)

        let limit = BudgetTemplateDraft.balanceLimit(amount: 500)
        guard let updatedLimit = BudgetTemplateEditorInputInterpreter.applying(
            "125.50",
            for: .amount,
            to: limit,
            currency: .usd
        ) else {
            Issue.record("Expected a valid limit amount")
            return
        }
        guard case .balanceLimit(let limitValue) = updatedLimit else {
            Issue.record("Expected a balance limit draft")
            return
        }
        #expect(limitValue.amount == 125.50)
    }
}
