import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func scheduleRefreshPublishesOneBudgetKeyedSnapshot() async throws {
        let bundle = try await makeScheduleStoreBundle()

        let loaded = try await bundle.store.refreshSchedules(
            budgetID: "group-1",
            asOf: "2026-09-27"
        )

        #expect(loaded.detail(id: "rent")?.status == .due)
        #expect(bundle.store.cachedSchedules(budgetID: "group-1") == loaded)
        #expect(bundle.store.cachedSchedules(budgetID: "another-budget") == nil)

        bundle.store.scheduleAutoPostRefusals = [ScheduleAutoPostRefusal(
            scheduleID: "rent", scheduleName: "Rent", occurrenceDayID: "2026-09-27",
            refusal: .draftMismatch
        )]
        bundle.store.reset()
        #expect(bundle.store.cachedSchedules(budgetID: "group-1") == nil)
        #expect(bundle.store.scheduleAutoPostRefusals.isEmpty)
    }

    @Test func newerScheduleRefreshRejectsOlderCompletionAndKeepsLatestAsOf() async throws {
        let bundle = try await makeScheduleStoreBundle()
        let gate = ScheduleStoreReadGate()
        gate.hold(today: "2026-09-27")
        bundle.store.scheduleReadHook = { _, today in
            await gate.pauseIfRequested(today: today)
        }
        defer {
            gate.release()
            bundle.store.scheduleReadHook = nil
        }

        let stale = scheduleRefreshTask(
            store: bundle.store,
            budgetID: "group-1",
            today: "2026-09-27",
            gate: gate
        )
        do {
            try await gate.waitUntilSuspended()

            let fresh = try await bundle.store.refreshSchedules(
                budgetID: "group-1",
                asOf: "2026-09-28"
            )
            #expect(fresh.detail(id: "rent")?.status == .missed)

            gate.release()
            await #expect(throws: CancellationError.self) {
                _ = try await stale.value
            }
            #expect(bundle.store.cachedSchedules(budgetID: "group-1") == fresh)
        } catch {
            await cancelAndDrain(stale, gate: gate)
            throw error
        }
    }

    @Test func preCancelledRefreshReleasedAfterValidRefreshStartsCannotSupersedeIt() async throws {
        let bundle = try await makeScheduleStoreBundle()
        let obsoleteMayEnter = TestLatch()
        let obsoleteGate = ScheduleStoreReadGate()
        let validGate = ScheduleStoreReadGate()
        validGate.hold(today: "2026-09-28")
        bundle.store.scheduleReadHook = { _, today in
            await validGate.pauseIfRequested(today: today)
        }
        defer {
            obsoleteMayEnter.trip()
            obsoleteGate.cancel()
            validGate.cancel()
            bundle.store.scheduleReadHook = nil
        }

        let obsolete = scheduleRefreshTask(
            store: bundle.store,
            budgetID: "group-1",
            today: "2026-09-27",
            gate: obsoleteGate,
            mayEnter: obsoleteMayEnter
        )
        obsolete.cancel()
        let valid = scheduleRefreshTask(
            store: bundle.store,
            budgetID: "group-1",
            today: "2026-09-28",
            gate: validGate
        )

        do {
            try await validGate.waitUntilSuspended()
            obsoleteMayEnter.trip()
            await #expect(throws: CancellationError.self) {
                _ = try await obsolete.value
            }
            validGate.release()
            let loaded = try await valid.value

            #expect(loaded.detail(id: "rent")?.status == .missed)
            #expect(bundle.store.cachedSchedules(budgetID: "group-1") == loaded)
        } catch {
            obsoleteMayEnter.trip()
            await cancelAndDrain(obsolete, gate: obsoleteGate)
            await cancelAndDrain(valid, gate: validGate)
            throw error
        }
    }

    @Test func cancelledScheduleRefreshCannotPublishAfterItsReadCompletes() async throws {
        let bundle = try await makeScheduleStoreBundle()
        let gate = ScheduleStoreReadGate()
        gate.hold(today: "2026-09-27")
        bundle.store.scheduleReadHook = { _, today in
            await gate.pauseIfRequested(today: today)
        }
        defer {
            gate.release()
            bundle.store.scheduleReadHook = nil
        }

        let pending = scheduleRefreshTask(
            store: bundle.store,
            budgetID: "group-1",
            today: "2026-09-27",
            gate: gate
        )
        do {
            try await gate.waitUntilSuspended()
            pending.cancel()
            gate.release()

            await #expect(throws: CancellationError.self) {
                _ = try await pending.value
            }
            #expect(bundle.store.cachedSchedules(budgetID: "group-1") == nil)
        } catch {
            await cancelAndDrain(pending, gate: gate)
            throw error
        }
    }

    @Test func scheduleGateWaitFailsIfRefreshCompletesBeforeTheReadHook() async throws {
        let bundle = try await makeScheduleStoreBundle()
        let gate = ScheduleStoreReadGate()
        gate.hold(today: "2026-09-27")
        bundle.store.scheduleReadHook = { _, today in
            await gate.pauseIfRequested(today: today)
        }
        defer {
            gate.cancel()
            bundle.store.scheduleReadHook = nil
        }
        let failed = scheduleRefreshTask(
            store: bundle.store,
            budgetID: "missing-budget",
            today: "2026-09-27",
            gate: gate
        )

        await #expect(throws: ScheduleStoreReadGateError.self) {
            try await gate.waitUntilSuspended()
        }
        await #expect(throws: LocalFirstError.self) {
            _ = try await failed.value
        }
    }

    @Test func sameBudgetReopenRejectsRetiredScheduleReadAndKeepsCacheClear() async throws {
        let bundle = try await makeScheduleStoreBundle()
        let gate = ScheduleStoreReadGate()
        gate.hold(today: "2026-09-27")
        bundle.store.scheduleReadHook = { _, today in
            await gate.pauseIfRequested(today: today)
        }
        defer {
            gate.release()
            bundle.store.scheduleReadHook = nil
        }

        let retired = scheduleRefreshTask(
            store: bundle.store,
            budgetID: "group-1",
            today: "2026-09-27",
            gate: gate
        )
        do {
            try await gate.waitUntilSuspended()
            bundle.store.closeOpenBudget()
            #expect(try await bundle.store.openCachedBudget(bundle.budget))
            gate.release()

            await #expect(throws: CancellationError.self) {
                _ = try await retired.value
            }
            #expect(bundle.store.cachedSchedules(budgetID: "group-1") == nil)
        } catch {
            await cancelAndDrain(retired, gate: gate)
            throw error
        }
    }

    @Test func transactionMutationInvalidatesCachedSchedulesAndPendingTickets() async throws {
        let bundle = try await makeScheduleStoreBundle()
        _ = try await bundle.store.refreshSchedules(
            budgetID: "group-1",
            asOf: "2026-09-27"
        )
        let gate = ScheduleStoreReadGate()
        gate.hold(today: "2026-09-27")
        bundle.store.scheduleReadHook = { _, today in
            await gate.pauseIfRequested(today: today)
        }
        defer {
            gate.release()
            bundle.store.scheduleReadHook = nil
        }
        let stale = scheduleRefreshTask(
            store: bundle.store,
            budgetID: "group-1",
            today: "2026-09-27",
            gate: gate
        )
        do {
            try await gate.waitUntilSuspended()

            let draft = TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 9, day: 27),
                amountMinorUnits: -10_000,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: "groceries",
                notes: nil,
                cleared: false,
                isTransfer: false
            )
            _ = try await bundle.store.createTransactionAndRefresh(
                draft,
                budgetID: "group-1"
            ) {}

            #expect(bundle.store.cachedSchedules(budgetID: "group-1") == nil)
            gate.release()
            await #expect(throws: CancellationError.self) {
                _ = try await stale.value
            }
        } catch {
            await cancelAndDrain(stale, gate: gate)
            throw error
        }
    }

    @Test func ruleMutationInvalidatesCachedSchedules() async throws {
        let bundle = try await makeScheduleStoreBundle()
        _ = try await bundle.store.refreshSchedules(
            budgetID: "group-1",
            asOf: "2026-09-27"
        )

        try await bundle.store.createRuleAndRefresh(
            budgetID: "group-1",
            draft: .categoryRule(payeeID: "coffee")
        )

        #expect(bundle.store.cachedSchedules(budgetID: "group-1") == nil)
    }

    private func makeScheduleStoreBundle() async throws -> OpenedWritableStoreBundle {
        try await makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.scheduleFixtureSQL)
    }

    private func scheduleRefreshTask(
        store: LocalFirstActualStore,
        budgetID: String,
        today: String,
        gate: ScheduleStoreReadGate,
        mayEnter: TestLatch? = nil
    ) -> Task<LoadedSchedules, Error> {
        Task { @MainActor in
            defer { gate.refreshCompleted() }
            if let mayEnter {
                await mayEnter.wait()
            }
            return try await store.refreshSchedules(budgetID: budgetID, asOf: today)
        }
    }

    private func cancelAndDrain(
        _ task: Task<LoadedSchedules, Error>,
        gate: ScheduleStoreReadGate
    ) async {
        task.cancel()
        gate.cancel()
        _ = try? await task.value
    }

    private static var scheduleFixtureSQL: String {
        """
        ALTER TABLE transactions ADD COLUMN schedule TEXT;
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            stage TEXT,
            conditions TEXT,
            actions TEXT,
            conditions_op TEXT DEFAULT 'and',
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules (
            id TEXT PRIMARY KEY,
            rule TEXT,
            name TEXT,
            completed INTEGER DEFAULT 0,
            posts_transaction INTEGER DEFAULT 0,
            custom_upcoming_length TEXT,
            sort_order REAL,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE schedules_next_date (
            id TEXT PRIMARY KEY,
            schedule_id TEXT,
            local_next_date INTEGER,
            local_next_date_ts INTEGER,
            base_next_date INTEGER,
            base_next_date_ts INTEGER,
            tombstone INTEGER DEFAULT 0
        );
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
        INSERT INTO preferences VALUES ('upcomingScheduledTransactionLength', '7');
        INSERT INTO rules (id, stage, conditions, actions, conditions_op, tombstone)
          VALUES (
            'rent-rule',
            'normal',
            '[{"op":"is","field":"account","value":"checking"},{"op":"is","field":"amount","value":-10000},{"op":"is","field":"date","value":"2026-09-27"}]',
            '[{"op":"link-schedule","value":"rent"}]',
            'and',
            0
          );
        INSERT INTO schedules
          VALUES ('rent', 'rent-rule', 'Rent', 0, 0, NULL, 1, 0);
        INSERT INTO schedules_next_date
          VALUES ('rent-next', 'rent', 20260927, 100, 20260927, 100, 0);
        """
    }
}

@MainActor
private final class ScheduleStoreReadGate {
    private var heldToday: String?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var didSuspend = false
    private var didComplete = false

    func hold(today: String) {
        heldToday = today
    }

    func pauseIfRequested(today: String) async {
        guard heldToday == today else { return }
        heldToday = nil
        didSuspend = true
        let waiters = suspensionWaiters.values
        suspensionWaiters = [:]
        waiters.forEach { $0.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                self.releaseContinuation = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.release()
            }
        }
        releaseContinuation = nil
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func refreshCompleted() {
        didComplete = true
        guard !didSuspend else { return }
        let waiters = suspensionWaiters.values
        suspensionWaiters = [:]
        waiters.forEach { $0.resume(throwing: ScheduleStoreReadGateError.refreshCompletedBeforeHook) }
    }

    func cancel() {
        heldToday = nil
        didComplete = true
        release()
        let waiters = suspensionWaiters.values
        suspensionWaiters = [:]
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }

    func waitUntilSuspended() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if didSuspend {
                    continuation.resume()
                } else if didComplete {
                    continuation.resume(throwing: ScheduleStoreReadGateError.refreshCompletedBeforeHook)
                } else {
                    suspensionWaiters[waiterID] = continuation
                }
            }
            try Task.checkCancellation()
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelWait(waiterID)
            }
        }
    }

    private func cancelWait(_ waiterID: UUID) {
        suspensionWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }
}

private enum ScheduleStoreReadGateError: Error {
    case refreshCompletedBeforeHook
}
