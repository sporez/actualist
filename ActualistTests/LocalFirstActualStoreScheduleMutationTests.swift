import Foundation
import Testing
@testable import Actualist

@MainActor
struct LocalFirstActualStoreScheduleMutationTests {
    private let support = LocalFirstActualStoreTests()

    @Test func sameBudgetReopenRejectsRetiredCreateAndReviewContexts() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let database = try #require(store.database)
        let context = try store.scheduleMutationSessionContext(budgetID: "group-1")
        let reviewed = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")

        store.closeOpenBudget()
        #expect(try await store.openCachedBudget(bundle.budget))

        await expectCommandError(.reviewChanged) {
            _ = try await store.createSchedule(createCommand, context: context)
        }
        await expectCommandError(.reviewChanged) {
            _ = try await store.updateSchedule(
                review: reviewed,
                fields: ScheduleEditFields(name: .set("Utilities")),
                asOfDayID: "2026-09-27",
                now: date(2026, 9, 27)
            )
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func closeDuringQueuedSubmissionRejectsOldDatabaseWrite() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let database = try #require(store.database)
        let reviewed = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")
        let gate = ScheduleMutationTestGate()
        store.scheduleMutationBeforeCommitHook = { await gate.pause() }
        defer {
            gate.release()
            store.scheduleMutationBeforeCommitHook = nil
        }

        let submission = Task { @MainActor in
            defer { gate.finish() }
            return try await store.updateSchedule(
                review: reviewed,
                fields: ScheduleEditFields(name: .set("Utilities")),
                asOfDayID: "2026-09-27",
                now: date(2026, 9, 27)
            )
        }
        do {
            guard await gate.waitUntilEntered() else {
                _ = try? await submission.value
                Issue.record("The reviewed submission ended before its pre-commit boundary.")
                return
            }
            store.closeOpenBudget()
            #expect(try await store.openCachedBudget(bundle.budget))
            gate.release()
            await expectCommandError(.reviewChanged) { _ = try await submission.value }

            #expect(try await database.pendingLocalSyncMessageCount() == 0)
            #expect(try await database.fetchSchedules(budgetID: "group-1", today: "2026-09-27")
                .detail(id: "rent")?.name == "Rent")
        } catch {
            submission.cancel()
            gate.release()
            _ = try? await submission.value
            throw error
        }
    }

    @Test func cancellationBeforeCommitWritesNothing() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let database = try #require(store.database)
        let reviewed = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")
        let gate = ScheduleMutationTestGate()
        store.scheduleMutationBeforeCommitHook = { await gate.pause() }
        defer {
            gate.release()
            store.scheduleMutationBeforeCommitHook = nil
        }

        let submission = Task { @MainActor in
            defer { gate.finish() }
            return try await store.updateSchedule(
                review: reviewed,
                fields: ScheduleEditFields(name: .set("Cancelled")),
                asOfDayID: "2026-09-27",
                now: date(2026, 9, 27)
            )
        }
        do {
            guard await gate.waitUntilEntered() else {
                _ = try? await submission.value
                Issue.record("The reviewed submission ended before its pre-commit boundary.")
                return
            }
            submission.cancel()
            gate.release()
            await #expect(throws: CancellationError.self) { _ = try await submission.value }
            #expect(try await database.pendingLocalSyncMessageCount() == 0)
            #expect(try await database.fetchSchedules(budgetID: "group-1", today: "2026-09-27")
                .detail(id: "rent")?.name == "Rent")
        } catch {
            submission.cancel()
            gate.release()
            _ = try? await submission.value
            throw error
        }
    }

    @Test func unchangedEditKeepsSnapshotAndDoesNotFlush() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let database = try #require(store.database)
        let loaded = try await store.refreshSchedules(budgetID: "group-1", asOf: "2026-09-27")
        let review = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")
        let pendingBefore = try await database.pendingLocalSyncMessageCount()
        let refreshCounter = ScheduleMutationFlag()
        store.scheduleMutationBeforeRefreshHook = { refreshCounter.value = true }

        let outcome = try await store.updateSchedule(
            review: review,
            fields: ScheduleEditFields(),
            asOfDayID: "2026-09-27",
            now: date(2026, 9, 27)
        )

        #expect(outcome.receipt.kind == .unchanged)
        #expect(!outcome.refreshPending)
        #expect(!refreshCounter.value)
        #expect(store.cachedSchedules(budgetID: "group-1") == loaded)
        #expect(try await database.pendingLocalSyncMessageCount() == pendingBefore)
    }

    @Test func duplicateNameAndIdentityErrorsRemainTypedThroughStoreCommit() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let context = try store.scheduleMutationSessionContext(budgetID: "group-1")
        await expectCommandError(.duplicateName) {
            _ = try await store.createSchedule(createCommand(name: " Rent "), context: context)
        }

        let database = try #require(store.database)
        let newNameWithExistingIdentity = createCommand(name: "Utilities")
        // Use a new name so the schedule-ID collision is the deciding failure.
        let first = try await store.createSchedule(newNameWithExistingIdentity, context: context)
        #expect(first.receipt.kind == .created)
        let pendingAfterCreate = try await database.pendingLocalSyncMessageCount()
        await expectCommandError(.identityConflict) {
            _ = try await store.createSchedule(createCommand(name: "Other"), context: context)
        }
        #expect(try await database.pendingLocalSyncMessageCount() == pendingAfterCreate)

        let rentReview = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")
        await expectCommandError(.duplicateName) {
            _ = try await store.updateSchedule(
                review: rentReview,
                fields: ScheduleEditFields(name: .set(" Utilities ")),
                asOfDayID: "2026-09-27",
                now: date(2026, 9, 27)
            )
        }
        #expect(try await database.fetchSchedules(budgetID: "group-1", today: "2026-09-27")
            .detail(id: "rent")?.name == "Rent")
    }

    @Test func caseVariantScheduleNamesRemainDistinct() async throws {
        let bundle = try await makeBundle()
        let context = try bundle.store.scheduleMutationSessionContext(budgetID: "group-1")

        let outcome = try await bundle.store.createSchedule(
            createCommand(name: "rent"),
            context: context
        )

        #expect(outcome.receipt.kind == .created)
        let loaded = try #require(bundle.store.cachedSchedules(budgetID: "group-1"))
        #expect(loaded.detail(id: "rent")?.name == "Rent")
        #expect(loaded.detail(id: "new-schedule")?.name == "rent")
    }

    @Test func tombstonedScheduleNameCanBeReused() async throws {
        let bundle = try await makeBundle(
            additionalFixtureSQL: "UPDATE schedules SET tombstone = 1 WHERE id = 'rent';"
        )
        let context = try bundle.store.scheduleMutationSessionContext(budgetID: "group-1")

        let outcome = try await bundle.store.createSchedule(
            createCommand(name: "Rent"),
            context: context
        )

        #expect(outcome.receipt.kind == .created)
        let loaded = try #require(bundle.store.cachedSchedules(budgetID: "group-1"))
        #expect(loaded.detail(id: "rent") == nil)
        #expect(loaded.detail(id: "new-schedule")?.name == "Rent")
    }

    @Test func durableCommitSurvivesCallerCancellationAndRefreshFailure() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")
        let holder = ScheduleMutationTaskHolder()
        store.scheduleMutationAfterCommitHook = { holder.task?.cancel() }
        holder.task = Task { @MainActor in
            try await store.updateSchedule(
                review: review,
                fields: ScheduleEditFields(name: .set("Paid Rent")),
                asOfDayID: "2026-09-27",
                now: date(2026, 9, 27)
            )
        }

        let submission = try #require(holder.task)
        let outcome = try await submission.value
        #expect(submission.isCancelled)
        #expect(outcome.receipt.kind == .updated)
        #expect(!outcome.refreshPending)
        #expect(store.cachedSchedules(budgetID: "group-1")?.detail(id: "rent")?.name == "Paid Rent")
        #expect(try await database.pendingLocalSyncMessageCount() > 0)

        let nextReview = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")
        store.scheduleMutationBeforeRefreshHook = { throw ScheduleMutationTestError.refreshFailed }
        let failedRefresh = try await store.updateSchedule(
            review: nextReview,
            fields: ScheduleEditFields(name: .set("Rent Updated")),
            asOfDayID: "2026-09-27",
            now: date(2026, 9, 27)
        )
        #expect(failedRefresh.receipt.kind == .updated)
        #expect(failedRefresh.refreshPending)
        #expect(store.cachedSchedules(budgetID: "group-1") == nil)
        #expect(try await database.fetchSchedules(budgetID: "group-1", today: "2026-09-27")
            .detail(id: "rent")?.name == "Rent Updated")
    }

    @Test func sessionReplacementAfterCommitKeepsReceiptOutOfNewSession() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")
        store.scheduleMutationAfterCommitHook = { [weak store] in
            guard let store else { return }
            store.closeOpenBudget()
            _ = try? await store.openCachedBudget(bundle.budget)
        }

        let outcome = try await store.updateSchedule(
            review: review,
            fields: ScheduleEditFields(name: .set("Committed")),
            asOfDayID: "2026-09-27",
            now: date(2026, 9, 27)
        )

        #expect(outcome.receipt.kind == .updated)
        #expect(outcome.refreshPending)
        #expect(try await database.fetchSchedules(budgetID: "group-1", today: "2026-09-27")
            .detail(id: "rent")?.name == "Committed")
        #expect(store.cachedSchedules(budgetID: "group-1") == nil)
    }

    @Test func staleRulesReadCannotRepublishAfterScheduleMutation() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        let gate = ScheduleMutationTestGate()
        store.rulesReadHook = { _ in await gate.pause() }
        defer {
            gate.release()
            store.rulesReadHook = nil
        }
        let obsoleteRead = Task { @MainActor in
            defer { gate.finish() }
            try await store.refreshRules(budgetID: "group-1")
        }
        do {
            guard await gate.waitUntilEntered() else {
                _ = try? await obsoleteRead.value
                Issue.record("The obsolete rules read ended before its publication boundary.")
                return
            }

            store.rulesReadHook = nil
            let review = try await store.scheduleMutationReview(budgetID: "group-1", scheduleID: "rent")
            _ = try await store.updateSchedule(
                review: review,
                fields: ScheduleEditFields(name: .set("Renamed")),
                asOfDayID: "2026-09-27",
                now: date(2026, 9, 27)
            )
            let currentRules = try #require(store.cachedRules(budgetID: "group-1"))
            gate.release()
            await #expect(throws: CancellationError.self) { try await obsoleteRead.value }
            #expect(store.cachedRules(budgetID: "group-1") == currentRules)
        } catch {
            obsoleteRead.cancel()
            gate.release()
            _ = try? await obsoleteRead.value
            throw error
        }
    }

    private func makeBundle(
        additionalFixtureSQL: String = ""
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.scheduleFixtureSQL + additionalFixtureSQL
        )
    }

    private func expectCommandError(
        _ expected: ScheduleMutationCommandError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected schedule command error \(expected)")
        } catch let error as ScheduleMutationCommandError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), received \(error)")
        }
    }

    private var createCommand: ScheduleCreateCommand { createCommand(name: "Utilities") }

    private func createCommand(name: String) -> ScheduleCreateCommand {
        ScheduleCreateCommand(
            budgetID: "group-1",
            identity: ScheduleCreateIdentity(scheduleID: "new-schedule", ruleID: "new-rule", nextDateID: "new-date"),
            name: name,
            definition: ScheduleDefinitionDraft(
                accountID: "checking",
                payeeMappingID: nil,
                amount: .exact(-500),
                dateRule: .oneTime(dayID: "2026-10-01", operation: "is")
            ),
            postsTransaction: false,
            customUpcomingLength: nil,
            asOfDayID: "2026-09-27"
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }

    private static let scheduleFixtureSQL = """
        ALTER TABLE transactions ADD COLUMN schedule TEXT;
        CREATE TABLE rules (
            id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
            conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules (
            id TEXT PRIMARY KEY, rule TEXT, name TEXT, completed INTEGER DEFAULT 0,
            posts_transaction INTEGER DEFAULT 0, custom_upcoming_length TEXT,
            sort_order REAL, tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules_next_date (
            id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER,
            local_next_date_ts INTEGER, base_next_date INTEGER, base_next_date_ts INTEGER,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
        INSERT INTO preferences VALUES ('upcomingScheduledTransactionLength', '7');
        INSERT INTO rules VALUES (
            'rent-rule', 'normal',
            '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000},{"op":"is","field":"date","value":"2026-09-27"}]',
            '[{"op":"link-schedule","value":"rent"}]', 'and', 0
        );
        INSERT INTO schedules VALUES ('rent', 'rent-rule', 'Rent', 0, 0, NULL, 1, 0);
        INSERT INTO schedules_next_date VALUES ('rent-next', 'rent', 20260927, 100, 20260927, 100, 0);
        """
}

@MainActor
private final class ScheduleMutationTestGate {
    private var hasEntered = false
    private var hasFinished = false
    private var releaseRequested = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        hasEntered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if releaseRequested || Task.isCancelled {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release() }
        }
    }

    func waitUntilEntered() async -> Bool {
        if hasEntered { return true }
        if hasFinished { return false }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || hasFinished {
                    continuation.resume()
                } else {
                    entryWaiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelEntryWait() }
        }
        return hasEntered
    }

    func release() {
        releaseRequested = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func finish() {
        hasFinished = true
        if !hasEntered {
            entryWaiter?.resume()
            entryWaiter = nil
        }
    }

    private func cancelEntryWait() {
        entryWaiter?.resume()
        entryWaiter = nil
    }
}

@MainActor
private final class ScheduleMutationTaskHolder {
    var task: Task<ScheduleMutationOutcome, Error>?
}

@MainActor
private final class ScheduleMutationFlag {
    var value = false
}

private enum ScheduleMutationTestError: Error {
    case refreshFailed
}
