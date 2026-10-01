import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

@MainActor
@Suite("Budget database schedule writes")
struct BudgetDatabaseScheduleWriteTests {
    private let support = LocalFirstActualStoreTests()

    private struct Fixture {
        let url: URL
        let database: BudgetDatabase
        let mutationRevisionCalls: MutationCounter
    }

    private final class MutationCounter: Sendable {
        private let storage = Mutex(0)
        func increment() { storage.withLock { $0 += 1 } }
        var value: Int { storage.withLock { $0 } }
    }

    @Test func metadataEditLeavesMalformedRuleBytesAndNextDateUntouched() async throws {
        let fixture = try makeFixture(
            conditions: "{not-json",
            actions: #"[{"op":"link-schedule","value":"schedule","future":true}]"#
        )
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let result = try await fixture.database.updateSchedule(
            review: review,
            fields: ScheduleEditFields(name: .set("  Updated  ")),
            asOfDayID: "2026-09-27",
            now: date(2026, 9, 27)
        )

        #expect(result.kind == .updated)
        #expect(try readString("SELECT conditions FROM rules WHERE id = 'rule'", fixture.url) == "{not-json")
        #expect(try readString("SELECT actions FROM rules WHERE id = 'rule'", fixture.url) ==
                #"[{"op":"link-schedule","value":"schedule","future":true}]"#)
        #expect(try readString("SELECT name FROM schedules WHERE id = 'schedule'", fixture.url) == "Updated")
        #expect(try readString("SELECT local_next_date_ts FROM schedules_next_date WHERE id = 'next'", fixture.url) == "100")
        #expect(try readString("SELECT base_next_date_ts FROM schedules_next_date WHERE id = 'next'", fixture.url) == "100")
    }

    @Test func amountEditPreservesUnknownJSONAndSynchronizesOnlyPlainSetAmount() async throws {
        let conditions = #"[{"op":"is","field":"account","value":"checking","futureCondition":7},{"op":"is","field":"amount","value":-100,"futureAmount":true},{"op":"is","field":"date","value":"2026-10-01","futureDate":[true,2]}]"#
        let actions = #"[{"op":"link-schedule","value":"schedule","futureLink":"keep"},{"op":"set","field":"amount","value":-100,"custom":"keep"},{"op":"set","field":"amount","value":-5,"options":{"formula":"=1+1"},"other":true}]"#
        let fixture = try makeFixture(conditions: conditions, actions: actions)
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        _ = try await fixture.database.updateSchedule(
            review: review,
            fields: ScheduleEditFields(amount: .set(.exact(-250))),
            asOfDayID: "2026-09-27",
            now: date(2026, 9, 27)
        )

        let updatedConditions = try #require(try readString("SELECT conditions FROM rules WHERE id = 'rule'", fixture.url))
        let updatedActions = try #require(try readString("SELECT actions FROM rules WHERE id = 'rule'", fixture.url))
        let decodedConditions = try JSONDecoder().decode([RuleJSONValue].self, from: Data(updatedConditions.utf8))
        let decodedActions = try JSONDecoder().decode([RuleJSONValue].self, from: Data(updatedActions.utf8))
        #expect(decodedConditions[0].objectValue?["futureCondition"] == .number(7))
        #expect(decodedConditions[1].objectValue?["futureAmount"] == .bool(true))
        #expect(decodedConditions[2].objectValue?["futureDate"] == .array([.bool(true), .number(2)]))
        #expect(decodedConditions[1].objectValue?["value"] == .number(-250))
        #expect(decodedConditions[1].objectValue?["op"] == .string("is"))
        #expect(decodedActions[0].objectValue?["futureLink"] == .string("keep"))
        #expect(decodedActions[1].objectValue?["value"] == .number(-250))
        #expect(decodedActions[1].objectValue?["custom"] == .string("keep"))
        #expect(decodedActions[2].objectValue?["value"] == .number(-5))
        #expect(decodedActions[2].objectValue?["other"] == .bool(true))
    }

    @Test func amountModeTransitionsPersistOperatorValueAndPlainAction() async throws {
        let modes: [(ScheduleAmountDraft, String, Int, ScheduleAmount)] = [
            (.exact(-10), "is", -10, .exact(-10)),
            (.approximate(-20), "isapprox", -20, .approximate(-20)),
            (.range(lower: -40, upper: -20), "isbetween", -30,
              .range(lower: -40, upper: -20, postingAmount: -30))
        ]
        let initialValues = [("is", "-100"), ("isapprox", "-200"), ("isbetween", #"{"num1":-200,"num2":-100}"#)]
        for (initialOperation, initialValue) in initialValues {
            for (draft, expectedOperation, expectedPostingAmount, expectedProjection) in modes {
                let conditions = """
                    [{"op":"is","field":"account","value":"checking"},
                     {"op":"\(initialOperation)","field":"amount","value":\(initialValue)},
                     {"op":"is","field":"date","value":"2026-10-01"}]
                    """
                let actions = #"[{"op":"link-schedule","value":"schedule"},{"op":"set","field":"amount","value":-100,"custom":true}]"#
                let fixture = try makeFixture(conditions: conditions, actions: actions)
                let review = try await fixture.database.scheduleMutationReview(
                    budgetID: "budget", scheduleID: "schedule"
                )
                _ = try await fixture.database.updateSchedule(
                    review: review,
                    fields: ScheduleEditFields(amount: .set(draft)),
                    asOfDayID: "2026-09-27",
                    now: date(2026, 9, 27)
                )
                let conditionJSON = try #require(try readString("SELECT conditions FROM rules WHERE id = 'rule'", fixture.url))
                let condition = try #require(JSONDecoder().decode([RuleCondition].self, from: Data(conditionJSON.utf8))
                    .first { $0.field == "amount" })
                #expect(condition.operation == expectedOperation)
                #expect(ScheduleRuleProjection.read(
                    scheduleID: "schedule",
                    conditionsJSON: conditionJSON,
                    actionsJSON: actions
                ).amount == expectedProjection)
                let actionJSON = try #require(try readString("SELECT actions FROM rules WHERE id = 'rule'", fixture.url))
                let action = try #require(JSONDecoder().decode([RuleJSONValue].self, from: Data(actionJSON.utf8))
                    .first { $0.objectValue?["field"] == .string("amount") })
                #expect(action.objectValue?["value"] == .number(Double(expectedPostingAmount)))
                #expect(action.objectValue?["custom"] == .bool(true))
            }
        }
    }

    @Test func everyAmountModeTransitionUpdatesOperatorAndProjection() throws {
        let modes: [(ScheduleAmountDraft, String, ScheduleAmount)] = [
            (.exact(-10), "is", .exact(-10)),
            (.approximate(-20), "isapprox", .approximate(-20)),
            (.range(lower: -40, upper: -20), "isbetween", .range(lower: -40, upper: -20, postingAmount: -30))
        ]
        for (from, _, _) in modes {
            for (to, expectedOperation, expectedAmount) in modes {
                let original = try ScheduleRuleMutation.newRuleJSON(
                    scheduleID: "schedule",
                    definition: ScheduleDefinitionDraft(
                        accountID: "checking", payeeMappingID: nil, amount: from,
                        dateRule: .oneTime(dayID: "2026-10-01", operation: "is")
                    )
                )
                let merged = try ScheduleRuleMutation.merge(
                    conditionsJSON: original.conditions,
                    actionsJSON: original.actions,
                    scheduleID: "schedule",
                    edits: ScheduleEditFields(amount: .set(to))
                )
                let conditions = try JSONDecoder().decode(
                    [RuleCondition].self,
                    from: Data((merged.conditions ?? original.conditions).utf8)
                )
                let amountCondition = try #require(conditions.first { $0.field == "amount" })
                #expect(amountCondition.operation == expectedOperation)
                let projection = ScheduleRuleProjection.read(
                    scheduleID: "schedule",
                    conditionsJSON: merged.conditions ?? original.conditions,
                    actionsJSON: merged.actions ?? original.actions
                )
                #expect(projection.amount == expectedAmount)
            }
        }
    }

    @Test func formulaAndTemplateOptionsUseJavaScriptTruthySemantics() throws {
        for (option, value, shouldPreserve) in [
            ("formula", RuleJSONValue.bool(true), true),
            ("formula", .bool(false), false),
            ("template", .bool(true), true),
            ("template", .bool(false), false),
            ("template", .null, false)
        ] {
            let options = RuleJSONValue.object([option: value])
            let action = RuleJSONValue.object([
                "op": .string("set"), "field": .string("amount"),
                "value": .number(-999), "options": options
            ])
            let actions = try JSONEncoder().encode([RuleJSONValue.object([
                "op": .string("link-schedule"), "value": .string("s")
            ]), action])
            let actionJSON = String(decoding: actions, as: UTF8.self)
            let conditions = #"[{"op":"is","field":"account","value":"a"},{"op":"is","field":"amount","value":-5},{"op":"is","field":"date","value":"2026-10-01"}]"#
            let merged = try ScheduleRuleMutation.merge(
                conditionsJSON: conditions,
                actionsJSON: actionJSON,
                scheduleID: "s",
                edits: ScheduleEditFields(accountID: .set("b"))
            )
            let decoded = try JSONDecoder().decode(
                [RuleJSONValue].self,
                from: Data((merged.actions ?? actionJSON).utf8)
            )
            let amount = try #require(decoded.last?.objectValue?["value"])
            #expect(amount == (shouldPreserve ? .number(-999) : .number(-5)))
        }
    }

    @Test func skipUsesRecurringRuleWithoutRewritingUnknownActions() async throws {
        let conditions = #"[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-100},{"op":"is","field":"date","value":{"start":"2026-10-02","frequency":"weekly","skipWeekend":true,"weekendSolveMode":"before"}}]"#
        let actions = #"[{"op":"link-schedule","value":"schedule"},{"op":"future-action","value":{"keep":true}}]"#
        let fixture = try makeFixture(conditions: conditions, actions: actions, nextDate: "2026-10-02")
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let result = try await fixture.database.skipNextDate(review: review, now: date(2026, 9, 27))

        #expect(result.kind == .skipped)
        #expect(try readString("SELECT local_next_date FROM schedules_next_date WHERE id = 'next'", fixture.url) == "20261009")
        #expect(try readString("SELECT local_next_date_ts FROM schedules_next_date WHERE id = 'next'", fixture.url) == "100")
        #expect(try readString("SELECT base_next_date FROM schedules_next_date WHERE id = 'next'", fixture.url) == "20261002")
        #expect(try readString("SELECT actions FROM rules WHERE id = 'rule'", fixture.url) == actions)
    }

    @Test func dateResetChangesBaseOnlyWhenCalculatedDateDiffers() async throws {
        let conditions = #"[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-100},{"op":"is","field":"date","value":{"start":"2026-09-27","frequency":"weekly"}}]"#
        let fixture = try makeFixture(conditions: conditions, nextDate: "2026-09-27")
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let sameDate = try await fixture.database.updateSchedule(
            review: review,
            fields: ScheduleEditFields(resetNextDate: true),
            asOfDayID: "2026-09-27",
            now: date(2026, 10, 1)
        )
        #expect(sameDate.kind == .unchanged)
        #expect(try readString("SELECT base_next_date_ts FROM schedules_next_date WHERE id = 'next'", fixture.url) == "100")

        let freshReview = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let changedDate = try await fixture.database.updateSchedule(
            review: freshReview,
            fields: ScheduleEditFields(resetNextDate: true),
            asOfDayID: "2026-09-28",
            now: date(2026, 10, 1)
        )
        #expect(changedDate.kind == .updated)
        #expect(try readString("SELECT base_next_date FROM schedules_next_date WHERE id = 'next'", fixture.url) == "20261004")
        #expect(try readString("SELECT base_next_date_ts FROM schedules_next_date WHERE id = 'next'", fixture.url) == millisecondTimestamp(for: date(2026, 10, 1)))
    }

    @Test func completeIsOneTimeOnlyAndRepeatedReviewedCompleteIsNoOp() async throws {
        let fixture = try makeFixture(conditions: oneTimeConditions)
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let completed = try await fixture.database.completeSchedule(review: review)
        #expect(completed.kind == .completed)
        let after = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let noOp = try await fixture.database.completeSchedule(review: after)
        #expect(noOp.kind == .unchanged)
        #expect(noOp.appliedMessageCount == 0)
        #expect(try readString("SELECT completed FROM schedules WHERE id = 'schedule'", fixture.url) == "1")
    }

    @Test func unchangedReviewedValuesDoNotAdvanceClockRevisionMessagesOutboxOrHistory() async throws {
        let fixture = try makeFixture()
        try installOutboxSentinel(fixture.url)
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let clockBefore = await fixture.database.localClock?.lastTimestamp
        let snapshotBefore = try databaseSnapshot(fixture.url)
        let revisionCallbackCountBefore = fixture.mutationRevisionCalls.value
        let result = try await fixture.database.updateSchedule(
            review: review,
            fields: ScheduleEditFields(
                name: .set("  Rent  "),
                accountID: .set("checking"),
                payeeMappingID: .set(nil),
                amount: .set(.exact(-100)),
                dateRule: .set(.oneTime(dayID: "2026-10-01", operation: "is")),
                postsTransaction: false,
                customUpcomingLength: .set(nil)
            ),
            asOfDayID: "2026-09-27",
            now: date(2026, 9, 27)
        )

        #expect(result.kind == .unchanged)
        #expect(result.appliedMessageCount == 0)
        #expect(try databaseSnapshot(fixture.url) == snapshotBefore)
        #expect(await fixture.database.localClock?.lastTimestamp == clockBefore)
        #expect(fixture.mutationRevisionCalls.value == revisionCallbackCountBefore)
        #expect(try readString("SELECT conditions FROM rules WHERE id = 'rule'", fixture.url) == oneTimeConditions)
        #expect(try readString("SELECT actions FROM rules WHERE id = 'rule'", fixture.url) == #"[{"op":"link-schedule","value":"schedule"}]"#)
        #expect(try readString("SELECT name FROM schedules WHERE id = 'schedule'", fixture.url) == "Rent")
        #expect(try readString("SELECT posts_transaction FROM schedules WHERE id = 'schedule'", fixture.url) == "0")
        #expect(try readString("SELECT local_next_date FROM schedules_next_date WHERE id = 'next'", fixture.url) == "20261001")
        #expect(try readString("SELECT base_next_date_ts FROM schedules_next_date WHERE id = 'next'", fixture.url) == "100")
    }

    @Test(arguments: ["rules", "schedules", "schedules_next_date", "messages_crdt", "actualist_outbox"])
    func atomicWriteFailureRollsBackEntitiesMessagesOutboxClockRevisionAndHistory(table: String) async throws {
        let fixture = try makeFixture()
        try installOutboxSentinel(fixture.url)
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let event = ["messages_crdt", "actualist_outbox"].contains(table) ? "INSERT" : "UPDATE"
        try execute(fixture.url, sql: """
            CREATE TRIGGER reject_schedule_mutation
            BEFORE \(event) ON \(table)
            BEGIN SELECT RAISE(ABORT, 'schedule write rejected'); END;
            """)
        let before = try databaseSnapshot(fixture.url)
        let clockBefore = await fixture.database.localClock?.lastTimestamp
        await #expect(throws: LocalFirstError.self) {
            try await fixture.database.updateSchedule(
                review: review,
                fields: ScheduleEditFields(
                    name: .set("Changed"),
                    amount: .set(.exact(-200)),
                    dateRule: .set(.oneTime(dayID: "2026-10-15", operation: "is"))
                ),
                asOfDayID: "2026-10-02",
                now: date(2026, 9, 27)
            )
        }

        #expect(try databaseSnapshot(fixture.url) == before)
        #expect(await fixture.database.localClock?.lastTimestamp == clockBefore)
        #expect(try readString("SELECT name FROM schedules WHERE id = 'schedule'", fixture.url) == "Rent")
        #expect(try readString("SELECT conditions FROM rules WHERE id = 'rule'", fixture.url) == oneTimeConditions)
        #expect(try readString("SELECT base_next_date FROM schedules_next_date WHERE id = 'next'", fixture.url) == "20261001")
    }

    @Test func metadataAndCompletionWorkWithoutNextDateSchemaButDateWritesRefuseIt() async throws {
        let metadata = try makeFixture(includeNextDate: false)
        let review = try await metadata.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let renamed = try await metadata.database.updateSchedule(
            review: review,
            fields: ScheduleEditFields(name: .set("Utilities")),
            asOfDayID: "2026-09-27",
            now: date(2026, 9, 27)
        )
        #expect(renamed.kind == .updated)

        let current = try await metadata.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let completed = try await metadata.database.completeSchedule(review: current)
        #expect(completed.kind == .completed)

        let dateWrite = try makeFixture(includeNextDate: false)
        let dateReview = try await dateWrite.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await dateWrite.database.updateSchedule(
                review: dateReview,
                fields: ScheduleEditFields(resetNextDate: true),
                asOfDayID: "2026-09-28",
                now: date(2026, 9, 27)
            )
        }
    }

    @Test func metadataAndCompletionRemainAvailableWithAmbiguousNextDateRows() async throws {
        let fixture = try makeFixture()
        try execute(fixture.url, sql: """
            INSERT INTO schedules_next_date
                (id, schedule_id, local_next_date, local_next_date_ts,
                 base_next_date, base_next_date_ts, tombstone)
            VALUES ('duplicate-next', 'schedule', 20261002, 100, 20261002, 100, 0)
            """)
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let renamed = try await fixture.database.updateSchedule(
            review: review,
            fields: ScheduleEditFields(name: .set("Utilities")),
            asOfDayID: "2026-09-27",
            now: date(2026, 9, 27)
        )
        #expect(renamed.kind == .updated)

        let current = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        #expect(try await fixture.database.completeSchedule(review: current).kind == .completed)
    }

    @Test func staleScheduleNextDateBaseTimestampAndAccountReviewsAreRejected() async throws {
        let scheduleChange = try makeFixture()
        let scheduleReview = try await scheduleChange.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        try execute(scheduleChange.url, sql: "UPDATE schedules SET posts_transaction = 1 WHERE id = 'schedule'")
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await scheduleChange.database.completeSchedule(review: scheduleReview)
        }

        let nextDateChange = try makeFixture()
        let nextDateReview = try await nextDateChange.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        try execute(nextDateChange.url, sql: "UPDATE schedules_next_date SET local_next_date_ts = 101 WHERE id = 'next'")
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await nextDateChange.database.completeSchedule(review: nextDateReview)
        }

        let baseChange = try makeFixture()
        let baseReview = try await baseChange.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        try execute(baseChange.url, sql: "UPDATE schedules_next_date SET base_next_date_ts = 200 WHERE id = 'next'")
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await baseChange.database.completeSchedule(review: baseReview)
        }

        let accountChange = try makeFixture()
        let accountReview = try await accountChange.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        try execute(accountChange.url, sql: "UPDATE accounts SET name = 'Renamed' WHERE id = 'checking'")
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await accountChange.database.completeSchedule(review: accountReview)
        }
    }

    @Test func cancellationAndInvalidatedSessionRejectBeforeAnyMutation() async throws {
        let canceled = try makeFixture()
        let canceledReview = try await canceled.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await canceled.database.completeSchedule(review: canceledReview)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try databaseSnapshot(canceled.url).messageCount == 0)

        let invalidated = try makeFixture()
        let invalidatedReview = try await invalidated.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        invalidated.database.invalidateSessionWrites()
        await #expect(throws: LocalFirstError.self) {
            try await invalidated.database.completeSchedule(review: invalidatedReview)
        }
        #expect(try databaseSnapshot(invalidated.url).messageCount == 0)
    }

    @Test func createRejectsInvalidAmountDateAndUpcomingInputsBeforeMutation() async throws {
        let fixture = try makeFixture()
        let validDefinition = ScheduleDefinitionDraft(
            accountID: "checking",
            payeeMappingID: nil,
            amount: .exact(-100),
            dateRule: .oneTime(dayID: "2026-10-01", operation: "is")
        )
        let invalidCommands = [
            ScheduleCreateCommand(
                budgetID: "budget",
                identity: ScheduleCreateIdentity(scheduleID: "bad-range", ruleID: "bad-range-rule", nextDateID: "bad-range-date"),
                name: "Bad range",
                definition: ScheduleDefinitionDraft(
                    accountID: "checking", payeeMappingID: nil,
                    amount: .range(lower: 1, upper: -1), dateRule: validDefinition.dateRule
                ),
                postsTransaction: false, customUpcomingLength: nil, asOfDayID: "2026-09-27"
            ),
            ScheduleCreateCommand(
                budgetID: "budget",
                identity: ScheduleCreateIdentity(scheduleID: "bad-date", ruleID: "bad-date-rule", nextDateID: "bad-date-row"),
                name: "Bad date",
                definition: ScheduleDefinitionDraft(
                    accountID: "checking", payeeMappingID: nil, amount: .exact(-100),
                    dateRule: .oneTime(dayID: "2026-02-30", operation: "is")
                ),
                postsTransaction: false, customUpcomingLength: nil, asOfDayID: "2026-09-27"
            ),
            ScheduleCreateCommand(
                budgetID: "budget",
                identity: ScheduleCreateIdentity(scheduleID: "bad-upcoming", ruleID: "bad-upcoming-rule", nextDateID: "bad-upcoming-date"),
                name: "Bad upcoming",
                definition: validDefinition,
                postsTransaction: false, customUpcomingLength: "tomorrow", asOfDayID: "2026-09-27"
            )
        ]
        for command in invalidCommands {
            await #expect(throws: ScheduleMutationCommandError.self) {
                try await fixture.database.createSchedule(command)
            }
        }
        #expect(try readInt("SELECT COUNT(*) FROM schedules", fixture.url) == 1)
        #expect(try databaseSnapshot(fixture.url).messageCount == 0)
    }

    @Test func deleteAllowsMalformedConditionsButRequiresUniqueMatchingLink() async throws {
        let fixture = try makeFixture(
            conditions: "{bad",
            actions: #"[{"op":"link-schedule","value":"schedule"}]"#
        )
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        let deleted = try await fixture.database.deleteSchedule(review: review)
        #expect(deleted.kind == .deleted)
        #expect(try readString("SELECT tombstone FROM schedules WHERE id = 'schedule'", fixture.url) == "1")
        #expect(try readString("SELECT tombstone FROM rules WHERE id = 'rule'", fixture.url) == "1")
        #expect(try readString("SELECT tombstone FROM schedules_next_date WHERE id = 'next'", fixture.url) == "0")

        let bad = try makeFixture(actions: #"[{"op":"link-schedule","value":"schedule"},{"op":"link-schedule","value":"schedule"}]"#)
        let badReview = try await bad.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await bad.database.deleteSchedule(review: badReview)
        }

        let malformed = try makeFixture(actions: "{malformed")
        let malformedReview = try await malformed.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await malformed.database.deleteSchedule(review: malformedReview)
        }
    }

    @Test func staleRuleReviewAndSharedRuleOwnerAreRejected() async throws {
        let fixture = try makeFixture()
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        try updateRuleActions(fixture.url, #"[{"op":"link-schedule","value":"schedule","remote":true}]"#)
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await fixture.database.completeSchedule(review: review)
        }

        let staleConditions = try makeFixture()
        let conditionReview = try await staleConditions.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        try execute(staleConditions.url, sql: "UPDATE rules SET conditions = '[{\"op\":\"is\",\"field\":\"amount\",\"value\":-200}]' WHERE id = 'rule'")
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await staleConditions.database.completeSchedule(review: conditionReview)
        }

        let shared = try makeFixture()
        try insertSharedSchedule(shared.url)
        let sharedReview = try await shared.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await shared.database.deleteSchedule(review: sharedReview)
        }
    }

    @Test func staleReviewIncludesTombstonedNextDateCandidateState() async throws {
        let fixture = try makeFixture()
        try execute(fixture.url, sql: """
            INSERT INTO schedules_next_date
                (id, schedule_id, local_next_date, local_next_date_ts,
                 base_next_date, base_next_date_ts, tombstone)
            VALUES ('retired-next', 'schedule', 20261002, 90, 20261002, 90, 1)
            """)
        let review = try await fixture.database.scheduleMutationReview(
            budgetID: "budget", scheduleID: "schedule"
        )
        try execute(fixture.url, sql: "UPDATE schedules_next_date SET base_next_date = 20261003 WHERE id = 'retired-next'")
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await fixture.database.completeSchedule(review: review)
        }
    }

    @Test func duplicateNameAndCreateIDCollisionDoNotMutateGraph() async throws {
        let fixture = try makeFixture()
        let command = ScheduleCreateCommand(
            budgetID: "budget",
            identity: ScheduleCreateIdentity(scheduleID: "new", ruleID: "new-rule", nextDateID: "new-date"),
            name: " Rent ",
            definition: ScheduleDefinitionDraft(
                accountID: "checking",
                payeeMappingID: nil,
                amount: .range(lower: -5_001, upper: -3_000),
                dateRule: .oneTime(dayID: "2026-10-01", operation: "is")
            ),
            postsTransaction: false,
            customUpcomingLength: nil,
            asOfDayID: "2026-09-27"
        )
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await fixture.database.createSchedule(command)
        }
        #expect(try readInt("SELECT COUNT(*) FROM schedules", fixture.url) == 1)

        let unique = ScheduleCreateCommand(
            budgetID: "budget",
            identity: command.identity,
            name: "  Utilities  ",
            definition: command.definition,
            postsTransaction: false,
            customUpcomingLength: nil,
            asOfDayID: "2026-09-27"
        )
        let created = try await fixture.database.createSchedule(unique, now: date(2026, 9, 27))
        #expect(created.kind == .created)
        #expect(try readString("SELECT name FROM schedules WHERE id = 'new'", fixture.url) == "Utilities")
        #expect(try readString("SELECT local_next_date FROM schedules_next_date WHERE id = 'new-date'", fixture.url) == "20261001")
        #expect(try readString("SELECT posts_transaction FROM schedules WHERE id = 'new'", fixture.url) == "0")

        let collision = ScheduleCreateCommand(
            budgetID: "budget",
            identity: command.identity,
            name: "Other",
            definition: command.definition,
            postsTransaction: false,
            customUpcomingLength: nil,
            asOfDayID: "2026-09-27"
        )
        await #expect(throws: ScheduleMutationCommandError.self) {
            try await fixture.database.createSchedule(collision)
        }
        #expect(try readInt("SELECT COUNT(*) FROM schedules", fixture.url) == 2)
    }

    private var oneTimeConditions: String {
        #"[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-100},{"op":"is","field":"date","value":"2026-10-01"}]"#
    }

    private func makeFixture(
        conditions: String? = nil,
        actions: String = #"[{"op":"link-schedule","value":"schedule"}]"#,
        nextDate: String = "2026-10-01",
        includeNextDate: Bool = true
    ) throws -> Fixture {
        let conditions = conditions ?? oneTimeConditions
        let nextDateSQL = includeNextDate ? """
            -- Post-1691233396000 schedules_next_date schema includes tombstone.
            CREATE TABLE schedules_next_date (
                id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER,
                local_next_date_ts INTEGER, base_next_date INTEGER,
                base_next_date_ts INTEGER, tombstone INTEGER DEFAULT 0
            );
            INSERT INTO schedules_next_date VALUES ('next', 'schedule', \(nextDate.replacingOccurrences(of: "-", with: "")), 100, \(nextDate.replacingOccurrences(of: "-", with: "")), 100, 0);
            """ : ""
        let sql = """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
                conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
            );
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY, rule TEXT, name TEXT, active INTEGER DEFAULT 0,
                completed INTEGER DEFAULT 0, posts_transaction INTEGER DEFAULT 0,
                custom_upcoming_length TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0
            );
            INSERT INTO rules VALUES ('rule', NULL, '\(conditions)', '\(actions)', 'and', 0);
            INSERT INTO schedules VALUES ('schedule', 'rule', 'Rent', 0, 0, 0, NULL, 0, 0);
            """
        let mutationRevisionCalls = MutationCounter()
        let url = try support.makeSQLiteFixture(extraSQL: sql + nextDateSQL)
        let database = try BudgetDatabase(
            databaseURL: url,
            localNodeID: "schedule-test-node",
            beforeBudgetDataMutation: {
                mutationRevisionCalls.increment()
            }
        )
        return Fixture(url: url, database: database, mutationRevisionCalls: mutationRevisionCalls)
    }

    private struct DatabaseSnapshot: Equatable {
        let scheduleCount: Int
        let ruleCount: Int
        let nextDateCount: Int
        let messageCount: Int
        let outboxCount: Int
        let historyCount: Int
        let revision: String?
        let entityRows: [[String]]
    }

    private func databaseSnapshot(_ url: URL) throws -> DatabaseSnapshot {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in
            func count(_ table: String) throws -> Int {
                guard try Row.fetchOne(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                    arguments: [table]
                ) != nil else { return 0 }
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return DatabaseSnapshot(
                scheduleCount: try count("schedules"),
                ruleCount: try count("rules"),
                nextDateCount: try count("schedules_next_date"),
                messageCount: try count("messages_crdt"),
                outboxCount: try count("actualist_outbox"),
                historyCount: try count("actualist_action_log"),
                revision: try String.fetchOne(db, sql: "SELECT MAX(timestamp) FROM messages_crdt"),
                entityRows: try ["rules", "schedules", "schedules_next_date"].map { table in
                    guard try count(table) > 0 else { return [] }
                    return try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY id").map(\.description)
                }
            )
        }
    }

    private func installOutboxSentinel(_ url: URL) throws {
        try execute(url, sql: """
            CREATE TABLE actualist_outbox (
                timestamp TEXT PRIMARY KEY, dataset TEXT NOT NULL, row TEXT NOT NULL,
                column TEXT NOT NULL, value TEXT NOT NULL, base_timestamp TEXT NOT NULL,
                created_at TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
                last_attempt_at TEXT, last_error TEXT
            );
            INSERT INTO actualist_outbox
                (timestamp, dataset, row, column, value, base_timestamp, created_at)
            VALUES ('sentinel', 'local', 'row', 'column', 'S:value', 'base', '2026-09-27T00:00:00Z');
            """)
    }

    private func execute(_ url: URL, sql: String) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
    }

    private func readString(_ sql: String, _ url: URL) throws -> String? {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in
            if let value = try String.fetchOne(db, sql: sql) { return value }
            if let value = try Int64.fetchOne(db, sql: sql) { return String(value) }
            return nil
        }
    }

    private func readInt(_ sql: String, _ url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private func updateRuleActions(_ url: URL, _ actions: String) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE rules SET actions = ? WHERE id = 'rule'", arguments: [actions])
        }
    }

    private func insertSharedSchedule(_ url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO schedules (id, rule, tombstone) VALUES ('shared', 'rule', 0)")
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.actualScheduleGregorian.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func millisecondTimestamp(for date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero)))
    }
}

private extension RuleJSONValue {
    var objectValue: [String: RuleJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }
}
