import Foundation
import Testing
@testable import Actualist

@MainActor
private final class ActiveCounter {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var log: [String] = []

    func enter(_ name: String) {
        current += 1
        peak = max(peak, current)
        log.append(name)
    }

    func leave() {
        current -= 1
    }
}

@MainActor
struct ShortcutsWriteLockTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSession() async throws -> ShortcutsBudgetSession {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        return ShortcutsBudgetSession(appState: appState)
    }

    /// Main-actor jobs start in submission order, so awaiting a task submitted
    /// now completes only after every earlier-spawned task ran its first
    /// segment (which, for a write, ends with enqueueing itself as a waiter).
    private func runQueuedMainActorWork() async {
        await Task { @MainActor in }.value
    }

    @Test func overlappingWritesRunOneAtATimeInArrivalOrder() async throws {
        let session = try await makeSession()
        let counter = ActiveCounter()
        let aEntered = TestLatch()
        let aGate = TestLatch()
        let entered = TestLatch()
        let hold = TestLatch()
        var c: Task<Void, any Error>?

        let a = Task { @MainActor in
            try await session.withExclusiveWrite { _ in
                counter.enter("A")
                aEntered.trip()
                await aGate.wait()
                counter.leave()
                // A new intent arrives in the same main-actor turn in which A
                // finishes and hands the lock to the queued B.
                c = Task { @MainActor in
                    try await session.withExclusiveWrite { _ in
                        counter.enter("C")
                        entered.trip()
                        await hold.wait()
                        counter.leave()
                    }
                }
            }
        }
        await aEntered.wait()
        let b = Task { @MainActor in
            try await session.withExclusiveWrite { _ in
                counter.enter("B")
                entered.trip()
                await hold.wait()
                counter.leave()
            }
        }
        await runQueuedMainActorWork()
        #expect(session.queuedWriteCount == 1)

        aGate.trip()
        await entered.wait()
        await runQueuedMainActorWork()
        // Whoever owns the lock holds it; nobody may run alongside.
        #expect(counter.current == 1)
        #expect(counter.log == ["A", "B"])
        hold.trip()
        try await a.value
        try await b.value
        try await #require(c).value

        #expect(counter.peak == 1)
        #expect(counter.log == ["A", "B", "C"])
        #expect(session.queuedWriteCount == 0)
    }

    @Test func cancelledQueuedWriteNeverRunsItsClosure() async throws {
        let session = try await makeSession()
        let counter = ActiveCounter()
        let aEntered = TestLatch()
        let aGate = TestLatch()

        let a = Task { @MainActor in
            try await session.withExclusiveWrite { _ in
                counter.enter("A")
                aEntered.trip()
                await aGate.wait()
                counter.leave()
            }
        }
        await aEntered.wait()
        let b = Task { @MainActor in
            try await session.withExclusiveWrite { _ in
                counter.enter("B")
                counter.leave()
            }
        }
        await runQueuedMainActorWork()
        #expect(session.queuedWriteCount == 1)

        b.cancel()
        aGate.trip()
        try await a.value
        let result = await b.result

        #expect(throws: (any Error).self) { try result.get() }
        #expect(counter.log == ["A"])
        #expect(session.queuedWriteCount == 0)

        // The lock is free again for the next intent.
        try await session.withExclusiveWrite { _ in counter.enter("D"); counter.leave() }
        #expect(counter.log == ["A", "D"])
    }
}
