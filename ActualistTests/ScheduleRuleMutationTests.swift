import Foundation
import Testing
@testable import Actualist

@Suite("Schedule rule mutation")
struct ScheduleRuleMutationTests {
    @Test func skippedWeekendBeforeMovesFridayOccurrenceForward() throws {
        let recurrence = try ActualScheduleRecurrence(
            startDayID: "2026-10-03",
            frequency: .weekly,
            skipWeekend: true,
            weekendAdjustment: .before
        )
        #expect(try ScheduleRuleMutation.nextDateAfterSkip(
            recurrence: recurrence,
            currentDayID: "2026-10-02"
        ) == "2026-10-09")
    }

    @Test func skippedWeekendAfterMovesSaturdayOccurrenceForward() throws {
        let recurrence = try ActualScheduleRecurrence(
            startDayID: "2026-10-03",
            frequency: .weekly,
            skipWeekend: true,
            weekendAdjustment: .after
        )
        #expect(try ScheduleRuleMutation.nextDateAfterSkip(
            recurrence: recurrence,
            currentDayID: "2026-10-05"
        ) == "2026-10-12")
    }

    @Test func exhaustedRecurrenceFallsBackToItsLastOccurrenceNeverAnotherDate() throws {
        let recurrence = try ActualScheduleRecurrence(
            startDayID: "2026-09-27",
            frequency: .weekly,
            ending: .onDate("2026-09-27")
        )
        #expect(try ScheduleRuleMutation.initialNextDate(
            for: .recurring(recurrence, operation: "is"),
            asOf: "2026-09-28"
        ) == "2026-09-27")
        #expect(try ScheduleRuleMutation.updateNextDate(
            for: .recurring(recurrence, operation: "is"),
            asOf: "2026-09-28",
            currentEffectiveDate: "2026-09-27"
        ) == nil)
        #expect(try ScheduleRuleMutation.updateNextDate(
            for: .recurring(recurrence, operation: "is"),
            asOf: "2026-09-28",
            currentEffectiveDate: "2026-09-20"
        ) == "2026-09-27")
    }

    @Test func conditionMergeKeepsUnrelatedArrayOrderAndUnknownObjectKeys() throws {
        let conditions = #"[{"op":"is","field":"notes","value":"memo","custom":false},{"op":"is","field":"amount","value":-5,"customAmount":[1,"x"]},{"op":"is","field":"date","value":"2026-10-01","dateOption":2}]"#
        let actions = #"[{"op":"link-schedule","value":"s","newKey":{"keep":true}},{"op":"set","field":"amount","value":-5,"actionExtra":1}]"#
        let merged = try ScheduleRuleMutation.merge(
            conditionsJSON: conditions,
            actionsJSON: actions,
            scheduleID: "s",
            edits: ScheduleEditFields(amount: .set(.range(lower: -3, upper: -2)))
        )
        let decodedConditions = try JSONDecoder().decode(
            [RuleJSONValue].self,
            from: Data(try #require(merged.conditions).utf8)
        )
        let decodedActions = try JSONDecoder().decode(
            [RuleJSONValue].self,
            from: Data(try #require(merged.actions).utf8)
        )
        #expect(decodedConditions[0].objectValue?["field"] == .string("notes"))
        #expect(decodedConditions[0].objectValue?["custom"] == .bool(false))
        #expect(decodedConditions[1].objectValue?["customAmount"] == .array([.number(1), .string("x")]))
        #expect(decodedConditions[2].objectValue?["dateOption"] == .number(2))
        #expect(decodedActions[0].objectValue?["newKey"] == .object(["keep": .bool(true)]))
        #expect(decodedActions[1].objectValue?["value"] == .number(-2))
        #expect(decodedActions[1].objectValue?["actionExtra"] == .number(1))
    }

    @Test func metadataOnlyRuleMergeReturnsNoRuleColumnsToRewrite() throws {
        let merged = try ScheduleRuleMutation.merge(
            conditionsJSON: "not-json",
            actionsJSON: #"[{"op":"link-schedule","value":"s","unknown":true}]"#,
            scheduleID: "s",
            edits: ScheduleEditFields(name: .set("New"))
        )
        #expect(merged.conditions == nil)
        #expect(merged.actions == nil)
    }

    @Test func dateEditPreservesUnknownKeysInsideTheRecurrenceValue() throws {
        let conditions = #"[{"op":"is","field":"account","value":"a"},{"op":"is","field":"amount","value":-5},{"op":"is","field":"date","value":{"start":"2026-10-01","frequency":"weekly","vendorExtension":{"keep":true}}}]"#
        let recurrence = try ActualScheduleRecurrence(
            startDayID: "2026-10-02",
            frequency: .monthly,
            patterns: [.dayOfMonth(2)]
        )
        let merged = try ScheduleRuleMutation.merge(
            conditionsJSON: conditions,
            actionsJSON: #"[{"op":"link-schedule","value":"s"}]"#,
            scheduleID: "s",
            edits: ScheduleEditFields(dateRule: .set(.recurring(recurrence, operation: "isapprox")))
        )
        let decoded = try JSONDecoder().decode(
            [RuleJSONValue].self,
            from: Data(try #require(merged.conditions).utf8)
        )
        #expect(decoded[2].objectValue?["value"]?.objectValue?["vendorExtension"] == .object(["keep": .bool(true)]))
        #expect(decoded[2].objectValue?["op"] == .string("isapprox"))
    }

    @Test func competingAccountAliasesAndUnsupportedDateOperatorAreNotEditableOrActionable() {
        let conditions = #"[{"op":"is","field":"account","value":"preferred"},{"op":"is","field":"acct","value":"competing"},{"op":"is","field":"amount","value":-5},{"op":"is","field":"date","value":"2026-10-01"},{"op":"future-op","field":"date","value":"2026-10-02"}]"#
        let actions = #"[{"op":"link-schedule","value":"s"},{"op":"custom-action","value":true}]"#
        let projection = ScheduleRuleProjection.read(
            scheduleID: "s",
            conditionsJSON: conditions,
            actionsJSON: actions
        )
        #expect(projection.accountID == "preferred")
        #expect(projection.capabilities.canEditMetadata)
        #expect(!projection.capabilities.canEditAccount)
        #expect(!projection.capabilities.canEditDate)
        #expect(!projection.capabilities.canSkip)
        #expect(!projection.capabilities.canComplete)
    }

    @Test func unsupportedAmountDoesNotDisableIndependentDateEditing() {
        let projection = ScheduleRuleProjection.read(
            scheduleID: "s",
            conditionsJSON: #"[{"op":"future-op","field":"amount","value":-5},{"op":"is","field":"date","value":"2026-10-01"}]"#,
            actionsJSON: #"[{"op":"link-schedule","value":"s"}]"#
        )
        #expect(projection.amount == .unavailable)
        #expect(!projection.capabilities.canEditAmount)
        #expect(projection.capabilities.canEditDate)
        #expect(projection.capabilities.canEditMetadata)
    }
}

private extension RuleJSONValue {
    var objectValue: [String: RuleJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    subscript(_ key: String) -> RuleJSONValue? {
        objectValue?[key]
    }
}
