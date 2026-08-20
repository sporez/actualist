import Testing
@testable import Actualist

@MainActor
struct AppSyncCoordinatorTests {
    @Test func sameBudgetRefreshesShareOneTask() async {
        let coordinator = AppSyncCoordinator()
        let gate = AppSyncOperationGate()

        let first = Task {
            await coordinator.refresh(budgetID: "budget", force: true) { _ in
                await gate.pause()
                return .succeeded
            }
        }
        while await gate.runCount == 0 {
            await Task.yield()
        }
        let second = Task {
            await coordinator.refresh(budgetID: "budget", force: true) { _ in
                Issue.record("A coalesced refresh must not start a second operation")
                return .failed(message: "duplicate", requiresReauthentication: false)
            }
        }

        await gate.resume()

        #expect(
            await first.value
                == AppSyncRefreshResult(outcome: .succeeded, shouldPublish: true)
        )
        #expect(
            await second.value
                == AppSyncRefreshResult(outcome: .succeeded, shouldPublish: false)
        )
        #expect(await gate.runCount == 1)
    }

    @Test func automaticRefreshRunsOncePerForegroundSession() async {
        let coordinator = AppSyncCoordinator()
        let counter = AppSyncOperationCounter()

        #expect(coordinator.beginForegroundSession())
        let first = await coordinator.refresh(budgetID: "budget", force: false) { _ in
            await counter.increment()
            return .succeeded
        }
        let duplicate = await coordinator.refresh(budgetID: "budget", force: false) { _ in
            Issue.record("Automatic refresh repeated in one foreground session")
            return .succeeded
        }

        coordinator.endForegroundSession()
        #expect(coordinator.beginForegroundSession())
        let nextSession = await coordinator.refresh(budgetID: "budget", force: false) { _ in
            await counter.increment()
            return .succeeded
        }

        #expect(first == AppSyncRefreshResult(outcome: .succeeded, shouldPublish: true))
        #expect(duplicate == AppSyncRefreshResult(outcome: .alreadyRequested, shouldPublish: false))
        #expect(nextSession == AppSyncRefreshResult(outcome: .succeeded, shouldPublish: true))
        #expect(await counter.value == 2)
    }

    @Test func endingSessionSuppressesCancellationInsensitiveCompletion() async {
        let coordinator = AppSyncCoordinator()
        let gate = AppSyncOperationGate()
        #expect(coordinator.beginForegroundSession())

        let task = Task {
            await coordinator.refresh(budgetID: "budget", force: false) { _ in
                await gate.pause()
                return .succeeded
            }
        }
        while await gate.runCount == 0 {
            await Task.yield()
        }

        coordinator.endForegroundSession()
        await gate.resume()

        #expect(
            await task.value
                == AppSyncRefreshResult(outcome: .cancelledOrStale, shouldPublish: true)
        )
    }

    @Test func differentBudgetReplacementCannotBeClearedByOldTask() async {
        let coordinator = AppSyncCoordinator()
        let gate = AppSyncOperationGate()

        let oldTask = Task {
            await coordinator.refresh(budgetID: "old", force: true) { _ in
                await gate.pause()
                return .failed(message: "old failure", requiresReauthentication: true)
            }
        }
        while await gate.runCount == 0 {
            await Task.yield()
        }

        let replacement = await coordinator.refresh(budgetID: "new", force: true) { _ in
            .succeeded
        }
        await gate.resume()

        #expect(replacement == AppSyncRefreshResult(outcome: .succeeded, shouldPublish: true))
        #expect(
            await oldTask.value
                == AppSyncRefreshResult(outcome: .cancelledOrStale, shouldPublish: true)
        )
    }

    @Test func automaticJoinConsumesTheSessionRequestWithoutPublishingTwice() async {
        let coordinator = AppSyncCoordinator()
        let gate = AppSyncOperationGate()
        #expect(coordinator.beginForegroundSession())

        let manual = Task {
            await coordinator.refresh(budgetID: "budget", force: true) { _ in
                await gate.pause()
                return .succeeded
            }
        }
        while await gate.runCount == 0 {
            await Task.yield()
        }

        let automatic = Task {
            await coordinator.refresh(budgetID: "budget", force: false) { _ in
                Issue.record("Automatic refresh should join the active manual operation")
                return .succeeded
            }
        }
        await gate.resume()

        #expect(
            await manual.value
                == AppSyncRefreshResult(outcome: .succeeded, shouldPublish: true)
        )
        #expect(
            await automatic.value
                == AppSyncRefreshResult(outcome: .succeeded, shouldPublish: false)
        )
        let duplicate = await coordinator.refresh(budgetID: "budget", force: false) { _ in
            Issue.record("Automatic refresh should already be consumed")
            return .succeeded
        }
        #expect(duplicate == AppSyncRefreshResult(outcome: .alreadyRequested, shouldPublish: false))
    }

    @Test func rejectedAutomaticReplacementDoesNotCancelActiveRefresh() async {
        let coordinator = AppSyncCoordinator()
        let gate = AppSyncOperationGate()
        #expect(coordinator.beginForegroundSession())

        _ = await coordinator.refresh(budgetID: "first", force: false) { _ in .succeeded }
        let active = Task {
            await coordinator.refresh(budgetID: "active", force: true) { _ in
                await gate.pause()
                return .succeeded
            }
        }
        while await gate.runCount == 0 {
            await Task.yield()
        }

        let rejected = await coordinator.refresh(budgetID: "replacement", force: false) { _ in
            Issue.record("A consumed automatic request must not run")
            return .succeeded
        }
        await gate.resume()

        #expect(rejected == AppSyncRefreshResult(outcome: .alreadyRequested, shouldPublish: false))
        #expect(
            await active.value
                == AppSyncRefreshResult(outcome: .succeeded, shouldPublish: true)
        )
    }

    @Test func automaticRefreshRequiresForegroundSession() async {
        let coordinator = AppSyncCoordinator()

        let result = await coordinator.refresh(budgetID: "budget", force: false) { _ in
            Issue.record("Automatic refresh ran without a foreground session")
            return .succeeded
        }

        #expect(result == AppSyncRefreshResult(outcome: .cancelledOrStale, shouldPublish: false))
    }
}

private actor AppSyncOperationGate {
    private(set) var runCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        runCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AppSyncOperationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
