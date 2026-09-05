import Foundation
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
}
