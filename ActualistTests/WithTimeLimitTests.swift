import Foundation
import Synchronization
import Testing
@testable import Actualist

@Suite("Operation time limits", .timeLimit(.minutes(2)))
@MainActor
struct WithTimeLimitTests {
    private enum Failure: Error { case timedOut, operation }

    @Test func completedOperationCancelsTheTimer() async throws {
        let timer = ManualTestDelay()
        let operation = ManualTestDelay()
        let task = Task {
            try await withTimeLimit(.seconds(5), timeoutError: Failure.timedOut, sleep: { try await timer.sleep(for: $0) }) {
                try await operation.sleep(for: .seconds(1))
                return 42
            }
        }
        #expect(try await timer.waitUntilSleeping() == .seconds(5))
        _ = try await operation.waitUntilSleeping()
        operation.resume()
        #expect(try await task.value == 42)
    }

    @Test func timeoutCancelsTheOperation() async throws {
        let timer = ManualTestDelay()
        let operation = ManualTestDelay()
        let task = Task {
            try await withTimeLimit(.seconds(5), timeoutError: Failure.timedOut, sleep: { try await timer.sleep(for: $0) }) {
                try await operation.sleep(for: .seconds(10))
            }
        }
        _ = try await timer.waitUntilSleeping()
        _ = try await operation.waitUntilSleeping()
        timer.resume()
        await #expect(throws: Failure.timedOut) { try await task.value }
    }

    @Test func parentCancellationCancelsBothChildren() async throws {
        let timer = ManualTestDelay()
        let operation = ManualTestDelay()
        let task = Task {
            try await withTimeLimit(.seconds(5), timeoutError: Failure.timedOut, sleep: { try await timer.sleep(for: $0) }) {
                try await operation.sleep(for: .seconds(10))
            }
        }
        _ = try await timer.waitUntilSleeping()
        _ = try await operation.waitUntilSleeping()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func operationErrorCancelsTheTimerAndKeepsItsError() async throws {
        let timer = ManualTestDelay()
        let operation = ManualTestDelay()
        let task = Task {
            try await withTimeLimit(.seconds(5), timeoutError: Failure.timedOut, sleep: { try await timer.sleep(for: $0) }) {
                try await operation.sleep(for: .seconds(1))
                throw Failure.operation
            }
        }
        _ = try await timer.waitUntilSleeping()
        _ = try await operation.waitUntilSleeping()
        operation.resume()
        await #expect(throws: Failure.operation) { try await task.value }
    }

    // MARK: withDeadline

    @MainActor
    private final class Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    @Test func deadlineReturnsAtTheLimitWhileOperationIgnoresCancellation() async throws {
        let timer = ManualTestDelay()
        let operationStarted = TestLatch()
        let operationGate = TestLatch()
        let operationEnded = TestLatch()
        let sawCancellation = Flag()
        let callerDone = TestLatch()
        let task = Task {
            try await withDeadline(.seconds(10), timeoutError: Failure.timedOut, sleep: { try await timer.sleep(for: $0) }) {
                operationStarted.trip()
                // Ignores cancellation until the test releases it.
                await operationGate.wait()
                if Task.isCancelled { sawCancellation.set() }
                operationEnded.trip()
                return 1
            }
        }
        Task { _ = await task.result; callerDone.trip() }
        func releaseGate() { operationGate.trip() }

        #expect(try await timer.waitUntilSleeping() == .seconds(10))
        #expect(await operationStarted.wait(timeout: .seconds(5), onTimeout: releaseGate))
        timer.resume()
        let returned = await callerDone.wait(timeout: .seconds(5), onTimeout: releaseGate)
        #expect(returned, "caller was held past the deadline by a non-cooperative operation")
        releaseGate()

        await #expect(throws: Failure.timedOut) { try await task.value }
        #expect(await operationEnded.wait(timeout: .seconds(5)))
        #expect(sawCancellation.isSet, "straggler was not cancelled at the deadline")
    }

    @Test func deadlineReturnsOperationValueAndCancelsTheTimer() async throws {
        let timer = ManualTestDelay()
        let timerCancelled = TestLatch()
        let operationGate = TestLatch()
        let task = Task {
            try await withDeadline(
                .seconds(5),
                timeoutError: Failure.timedOut,
                sleep: { duration in
                    do { try await timer.sleep(for: duration) } catch {
                        timerCancelled.trip()
                        throw error
                    }
                }
            ) {
                await operationGate.wait()
                return 42
            }
        }
        #expect(try await timer.waitUntilSleeping() == .seconds(5))
        operationGate.trip()
        #expect(try await task.value == 42)
        #expect(await timerCancelled.wait(timeout: .seconds(5)), "timer was not cancelled")
        // A late timer release is a no-op: the continuation resumed once.
        timer.resume()
    }

    @Test func deadlineKeepsOperationErrorAndCancelsTheTimer() async throws {
        let timer = ManualTestDelay()
        let operationGate = TestLatch()
        let task = Task {
            try await withDeadline(.seconds(5), timeoutError: Failure.timedOut, sleep: { try await timer.sleep(for: $0) }) {
                await operationGate.wait()
                throw Failure.operation
            }
        }
        _ = try await timer.waitUntilSleeping()
        operationGate.trip()
        await #expect(throws: Failure.operation) { try await task.value }
    }

    @Test func deadlineParentCancellationThrowsCancellationAndCancelsOperation() async throws {
        let timer = ManualTestDelay()
        let operation = ManualTestDelay()
        let task = Task {
            try await withDeadline(.seconds(5), timeoutError: Failure.timedOut, sleep: { try await timer.sleep(for: $0) }) {
                try await operation.sleep(for: .seconds(10))
            }
        }
        _ = try await timer.waitUntilSleeping()
        _ = try await operation.waitUntilSleeping()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
