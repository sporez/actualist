import Foundation
import Synchronization
import Testing
@testable import Actualist

@Suite("Background refresh task driver", .timeLimit(.minutes(2)))
@MainActor
struct BackgroundRefreshTaskDriverTests {
    private final class FakeRefreshTask: BackgroundRefreshTaskHandle, @unchecked Sendable {
        private let completions = Mutex<[Bool]>([])
        let completed = TestLatch()
        var expirationHandler: (() -> Void)?

        var completedWith: [Bool] { completions.withLock { $0 } }

        func setTaskCompleted(success: Bool) {
            completions.withLock { $0.append(success) }
            completed.trip()
        }

        func expire() {
            expirationHandler?()
        }
    }

    @Test func expirationCompletesAfterGraceWhenRefreshIgnoresCancellation() async throws {
        let task = FakeRefreshTask()
        let refreshGate = TestLatch()
        let graceStarted = TestLatch()
        let graceRelease = TestLatch()
        let driver = BackgroundRefreshTaskDriver.drive(
            task: task,
            expirationGrace: .seconds(2),
            sleep: { _ in
                graceStarted.trip()
                await graceRelease.wait()
            },
            refresh: {
                // Ignores cancellation until the test releases it.
                await refreshGate.wait()
                return true
            }
        )
        func releaseAll() {
            refreshGate.trip()
            graceRelease.trip()
        }

        task.expire()
        let graceArmed = await graceStarted.wait(timeout: .seconds(5), onTimeout: releaseAll)
        #expect(graceArmed, "expiration did not arm the grace completion")
        #expect(task.completedWith.isEmpty, "completed before the grace delay elapsed")

        graceRelease.trip()
        let completedAtGrace = await task.completed.wait(timeout: .seconds(5), onTimeout: releaseAll)
        #expect(completedAtGrace, "task was not completed after the grace delay")
        #expect(task.completedWith == [false])

        // A straggling refresh finishing later must not complete it again.
        refreshGate.trip()
        await driver.value
        #expect(task.completedWith == [false])
    }

    @Test func normalCompletionReportsRefreshResultOnce() async {
        let task = FakeRefreshTask()
        let refreshGate = TestLatch()
        let driver = BackgroundRefreshTaskDriver.drive(
            task: task,
            sleep: { _ in },
            refresh: {
                await refreshGate.wait()
                return true
            }
        )
        refreshGate.trip()
        await driver.value
        #expect(task.completedWith == [true])

        // Expiration after completion must not complete again.
        task.expire()
        let secondCompletion = await task.completed.wait(timeout: .milliseconds(200))
        #expect(secondCompletion)
        #expect(task.completedWith == [true])
    }
}
