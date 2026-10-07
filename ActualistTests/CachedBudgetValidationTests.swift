import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct CachedBudgetValidationTests {
    private let fixtures = LocalFirstActualStoreTests()

    private nonisolated static func blockingWait(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    @Test func validationWhileOpenSucceedsDuringAnotherConnectionsWrite() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let writer = try DatabaseQueue(path: url.path)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? writer.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS validation_probe (id INTEGER)")
                started.signal()
                Self.blockingWait(release)
            }
            finished.signal()
        }
        defer {
            release.signal()
            Self.blockingWait(finished)
        }
        await Task.detached { Self.blockingWait(started) }.value

        let canOpen = try await bundle.store.validateCachedBudgetCanOpen(bundle.budget)
        #expect(canOpen)
    }

    @Test func validationOfClosedCacheRunsNoCompatibilityWrites() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        bundle.store.reset()
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { try $0.execute(sql: "DROP TABLE actualist_budget_identity") }
        func identityTableExists() async throws -> Bool {
            try await queue.read {
                try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'actualist_budget_identity')") ?? false
            }
        }
        #expect(try await !identityTableExists())

        let canOpen = try await bundle.store.validateCachedBudgetCanOpen(bundle.budget)

        #expect(canOpen)
        #expect(try await !identityTableExists())
    }

    @Test func validationOfCorruptCacheStillThrows() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        bundle.store.reset()
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        try Data(repeating: 0x41, count: 4096).write(to: url)

        await #expect(throws: (any Error).self) {
            _ = try await bundle.store.validateCachedBudgetCanOpen(bundle.budget)
        }
    }

    @Test func untrustedFileConfigurationWaitsTwoSecondsForBusyFile() {
        let configuration = BudgetDatabase.untrustedFileConfiguration()
        guard case .timeout(let seconds) = configuration.busyMode else {
            Issue.record("busyMode was not a timeout")
            return
        }
        #expect(seconds == 2)
    }
}
