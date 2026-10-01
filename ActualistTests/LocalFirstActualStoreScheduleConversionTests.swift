import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct LocalFirstActualStoreScheduleConversionTests {
    private let support = LocalFirstActualStoreTests()

    @Test func sameBudgetReopenRejectsReviewedConversionBeforeWrite() async throws {
        let bundle = try await makeBundle()
        let databaseURL = try bundle.fileManager.databaseURL(fileID: try #require(bundle.budget.budgetID))
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.scheduleConversionReview(
            budgetID: "group-1",
            transactionID: "future",
            asOfDayID: Self.today
        )

        store.closeOpenBudget()
        #expect(try await store.openCachedBudget(bundle.budget))
        await #expect(throws: ScheduleConversionError.reviewChanged) {
            _ = try await store.convertFutureTransaction(review: review)
        }

        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try readInt("SELECT tombstone FROM transactions WHERE id='future'", databaseURL) == 0)
    }

    @Test func precommitCancellationDrainsAndWritesNothing() async throws {
        let bundle = try await makeBundle()
        let databaseURL = try bundle.fileManager.databaseURL(fileID: try #require(bundle.budget.budgetID))
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.scheduleConversionReview(
            budgetID: "group-1", transactionID: "future", asOfDayID: Self.today
        )
        let gate = ConversionCommitGate()
        store.scheduleMutationBeforeCommitHook = {
            await gate.pause()
        }
        defer {
            gate.release()
            store.scheduleMutationBeforeCommitHook = nil
        }

        let submission = Task { @MainActor in
            try await store.convertFutureTransaction(review: review)
        }
        guard await gate.waitForEntry() else {
            submission.cancel()
            gate.release()
            _ = await submission.result
            Issue.record("Conversion did not reach the precommit gate before its deadline")
            return
        }
        submission.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { _ = try await submission.value }

        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try readInt("SELECT tombstone FROM transactions WHERE id='future'", databaseURL) == 0)
        #expect(try readInt("SELECT COUNT(*) FROM schedules", databaseURL) == 0)
    }

    @Test func durableReceiptSurvivesCallerCancellationAndSessionRetirement() async throws {
        let bundle = try await makeBundle()
        let databaseURL = try bundle.fileManager.databaseURL(fileID: try #require(bundle.budget.budgetID))
        let store = bundle.store
        let database = try #require(store.database)
        let review = try await store.scheduleConversionReview(
            budgetID: "group-1", transactionID: "future", asOfDayID: Self.today
        )
        let holder = ConversionTaskHolder()
        store.scheduleMutationAfterCommitHook = { [weak store] in
            holder.task?.cancel()
            guard let store else { return }
            store.closeOpenBudget()
            _ = try? await store.openCachedBudget(bundle.budget)
        }
        holder.task = Task { @MainActor in
            try await store.convertFutureTransaction(review: review)
        }

        let submission = try #require(holder.task)
        let receipt = try await submission.value

        #expect(submission.isCancelled)
        #expect(receipt.scheduleID == review.identity.scheduleID)
        #expect(receipt.sourceTransactionIDs == ["future"])
        #expect(receipt.appliedMessageCount > 0)
        #expect(receipt.refreshPending)
        #expect(try await database.pendingLocalSyncMessageCount() > 0)
        #expect(try readInt("SELECT tombstone FROM transactions WHERE id='future'", databaseURL) == 1)
        #expect(store.cachedSchedules(budgetID: "group-1") == nil)
        #expect(store.transactionFeedPagesByKey.isEmpty)
    }

    @Test func successfulCurrentSessionRefreshesRulesAndRemovesOriginalFromPrimedFeed() async throws {
        let bundle = try await makeBundle()
        let store = bundle.store
        try await store.refreshRules(budgetID: "group-1")
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        let initialFeed = try #require(store.cachedAccountTransactions(
            budgetID: "group-1", accountID: "checking"
        ))
        #expect(initialFeed.transactions.contains { $0.id == "future" })
        #expect(store.cachedRules(budgetID: "group-1") != nil)

        let review = try await store.scheduleConversionReview(
            budgetID: "group-1", transactionID: "future", asOfDayID: Self.today
        )
        let receipt = try await store.convertFutureTransaction(review: review)

        #expect(!receipt.refreshPending)
        #expect(store.cachedRules(budgetID: "group-1")?.contains { $0.id == review.identity.ruleID } == true)
        let refreshedFeed = try #require(store.cachedAccountTransactions(
            budgetID: "group-1", accountID: "checking"
        ))
        #expect(!refreshedFeed.transactions.contains { $0.id == "future" })
    }

    @Test func failedFeedRefreshKeepsDurableWriteAndInvalidatesStaleCaches() async throws {
        let hook = ConversionFeedReadBehavior()
        let bundle = try await makeBundle(transactionFeedPageReadHook: { _, _, _, _ in
            try hook.read()
        })
        let databaseURL = try bundle.fileManager.databaseURL(fileID: try #require(bundle.budget.budgetID))
        let store = bundle.store
        try await store.refreshRules(budgetID: "group-1")
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        let initialFeed = try #require(store.cachedAccountTransactions(
            budgetID: "group-1", accountID: "checking"
        ))
        #expect(initialFeed.transactions.contains { $0.id == "future" })
        #expect(store.cachedRules(budgetID: "group-1") != nil)

        hook.failNextRead = true
        let review = try await store.scheduleConversionReview(
            budgetID: "group-1", transactionID: "future", asOfDayID: Self.today
        )
        let receipt = try await store.convertFutureTransaction(review: review)

        #expect(receipt.refreshPending)
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking") == nil)
        #expect(store.cachedRules(budgetID: "group-1") == nil)
        #expect(try readInt(
            "SELECT tombstone FROM transactions WHERE id='future'", databaseURL
        ) == 1)
        #expect(try readInt(
            "SELECT COUNT(*) FROM schedules WHERE id='\(review.identity.scheduleID)' AND tombstone=0",
            databaseURL
        ) == 1)
    }

    private func makeBundle(
        transactionFeedPageReadHook: TransactionFeedPageReadHook? = nil
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.conversionFixtureSQL,
            transactionFeedPageReadHook: transactionFeedPageReadHook
        )
    }

    private func readInt(_ sql: String, _ url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.readSync { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private static let today: String = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return ActualScheduleRecurrence.dayID(from: Date(), calendar: calendar)
    }()

    private static let conversionFixtureSQL: String = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = calendar.date(byAdding: .day, value: 1, to: Date())!
        let dateID = ActualScheduleRecurrence.dayID(from: date, calendar: calendar)
        let packedDate = Int(dateID.replacingOccurrences(of: "-", with: ""))!
        return """
            ALTER TABLE transactions ADD COLUMN schedule TEXT;
            UPDATE transactions SET id='future', date=\(packedDate), amount=-1200, notes='Memo' WHERE id='txn';
            CREATE TABLE rules (id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT, conditions_op TEXT DEFAULT 'and', tombstone INTEGER DEFAULT 0);
            CREATE TABLE schedules (id TEXT PRIMARY KEY, rule TEXT, name TEXT, active INTEGER DEFAULT 0, completed INTEGER DEFAULT 0, posts_transaction INTEGER DEFAULT 0, custom_upcoming_length TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0);
            CREATE TABLE schedules_next_date (id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER, local_next_date_ts INTEGER, base_next_date INTEGER, base_next_date_ts INTEGER, tombstone INTEGER DEFAULT 0);
            """
    }()
}

@MainActor
private final class ConversionTaskHolder {
    var task: Task<ScheduleConversionReceipt, Error>?
}

@MainActor
private final class ConversionCommitGate {
    private let entered = TestLatch()
    private let released = TestLatch()
    private var didEnter = false
    private var didTimeOut = false

    func pause() async {
        didEnter = true
        entered.trip()
        await released.wait()
    }

    func waitForEntry(timeout: Duration = .seconds(10)) async -> Bool {
        if didEnter { return true }
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !self.didEnter else { return }
            self.didTimeOut = true
            self.released.trip()
            self.entered.trip()
        }
        await entered.wait()
        deadline.cancel()
        return didEnter && !didTimeOut
    }

    func release() {
        released.trip()
    }
}

@MainActor
private final class ConversionFeedReadBehavior {
    var failNextRead = false

    func read() throws {
        guard failNextRead else { return }
        failNextRead = false
        throw ExpectedConversionFeedReadError.failed
    }
}

private enum ExpectedConversionFeedReadError: Error {
    case failed
}
