import Foundation
import Testing
@testable import Actualist

@MainActor
struct LocalFirstActualStoreAccountLifecycleTests {
    private let support = LocalFirstActualStoreTests()

    @Test func renameRefreshesAccountAndFeedNamesBeforeReturning() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let store = bundle.store
        try await store.refreshAccountsWithBalances(budgetID: "group-1")
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        let initialAccount = try #require(store.accountDisplays(budgetID: "group-1").first { $0.id == "checking" }?.account)
        let feed = AccountTransactionsViewModel(scope: .account(initialAccount))

        let result = try await store.renameAccountAndRefresh(
            budgetID: "group-1", command: renameCommand
        )

        guard case .applied(let outcome) = result else {
            Issue.record("Expected a durable rename")
            return
        }
        #expect(!outcome.refreshPending)
        #expect(store.accountDisplays(budgetID: "group-1").first { $0.id == "checking" }?.account.name == "Daily Spending")
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?.accountNames["checking"] == "Daily Spending")
        #expect(store.actionLogDiagnosticSnapshot.count == 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == 1)
        #expect(feed.displayState(
            budgetID: "group-1", repository: store,
            pendingNewTransactionIDs: [], privacyModeEnabled: false
        ).title == "Daily Spending")
        #expect(feed.displayState(
            budgetID: "group-1", repository: store,
            pendingNewTransactionIDs: [], privacyModeEnabled: true
        ).title == PrivacyDisplay.name(for: .account, seed: "checking"))
    }

    @Test func reopenRefreshesClosedAccountMembershipBeforeReturning() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: "UPDATE accounts SET closed = 1 WHERE id = 'checking';"
        )
        let result = try await bundle.store.reopenAccountAndRefresh(
            budgetID: "group-1",
            command: AccountReopenCommand(accountID: "checking", expectedClosed: true)
        )
        guard case .applied(let outcome) = result else {
            Issue.record("Expected a durable reopen")
            return
        }
        #expect(!outcome.refreshPending)
        #expect(!outcome.account.isClosed)
        #expect(bundle.store.accountDisplays(budgetID: "group-1").first { $0.id == "checking" }?.account.closed == false)
    }

    @Test func ordinaryCloseRefreshesClosedMembershipBeforeReturning() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: """
                UPDATE transactions SET amount = 0 WHERE id = 'txn';
                """
        )
        let request = AccountLifecycleReviewRequest(
            budgetID: "group-1",
            accountID: "checking",
            requestedAction: .close(destinationAccountID: nil, categoryID: nil)
        )
        let review = try await bundle.store.accountLifecycleReview(request: request)

        let result = try await bundle.store.commitAccountLifecycleAndRefresh(reviewed: review)

        guard case .applied(let outcome) = result else {
            Issue.record("Expected a durable close")
            return
        }
        #expect(!outcome.refreshPending)
        #expect(outcome.account.isClosed)
        #expect(bundle.store.accountDisplays(budgetID: "group-1")
            .first { $0.id == "checking" }?.account.closed == true)
    }

    @Test func closeRefreshFailureReportsCommittedRefreshPendingWithoutDuplicateWrite() async throws {
        let (store, hook) = try await makeStoreWithFeedHook(additionalFixtureSQL: """
            UPDATE transactions SET amount = 0 WHERE id = 'txn';
            """)
        let request = AccountLifecycleReviewRequest(
            budgetID: "group-1",
            accountID: "checking",
            requestedAction: .close(destinationAccountID: nil, categoryID: nil)
        )
        let review = try await store.accountLifecycleReview(request: request)
        hook.action = { throw LocalFirstTestSyncError.failed }

        let result = try await store.commitAccountLifecycleAndRefresh(reviewed: review)

        guard case .applied(let outcome) = result else {
            Issue.record("Refresh failure must retain the committed close")
            return
        }
        #expect(outcome.refreshPending)
        let database = try #require(store.database)
        #expect(try await database.fetchAccounts().first { $0.id == "checking" }?.closed == true)
        #expect(try await database.pendingLocalSyncMessageCount() == 1)
        #expect(try await database.recentBudgetActions().count == 1)
    }

    @Test func refreshFailureReturnsCommittedOutcomeAndRetryDoesNotDuplicateHistory() async throws {
        let (store, hook) = try await makeStoreWithFeedHook()
        hook.action = { throw LocalFirstTestSyncError.failed }

        let result = try await store.renameAccountAndRefresh(
            budgetID: "group-1", command: renameCommand
        )
        guard case .applied(let outcome) = result else {
            Issue.record("Refresh failure must not disguise a committed write")
            return
        }
        #expect(outcome.refreshPending)
        #expect(AccountLifecyclePresentation.mutationSheet(for: .completed(outcome)) == .savedRefreshPending)
        let database = try #require(store.database)
        #expect(try await database.fetchAccounts().first { $0.id == "checking" }?.name == "Daily Spending")
        #expect(try await database.pendingLocalSyncMessageCount() == 1)
        #expect(try await database.recentBudgetActions().count == 1)

        hook.action = nil
        let retry = try await store.renameAccountAndRefresh(
            budgetID: "group-1", command: renameCommand
        )
        guard case .noChange(let refreshed) = retry else {
            Issue.record("A completed command must be idempotent")
            return
        }
        #expect(!refreshed.refreshPending)
        #expect(AccountLifecyclePresentation.mutationSheet(for: .completed(refreshed)) == nil)
        #expect(try await database.recentBudgetActions().count == 1)
        #expect(try await database.pendingLocalSyncMessageCount() == 1)
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?.accountNames["checking"] == "Daily Spending")
    }

    @Test func sessionReplacementDuringRefreshCannotRepublishOldFeedsOrDiagnostics() async throws {
        let (store, hook) = try await makeStoreWithFeedHook()
        let originalDatabase = try #require(store.database)
        hook.action = { [weak store] in
            store?.closeOpenBudget()
            store?.openedBudgetID = "replacement-budget"
        }

        let result = try await store.renameAccountAndRefresh(
            budgetID: "group-1", command: renameCommand
        )
        guard case .applied(let outcome) = result else {
            Issue.record("The old budget's committed outcome remains durable")
            return
        }
        #expect(outcome.refreshPending)
        #expect(store.openedBudgetID == "replacement-budget")
        #expect(store.accountsByBudget.isEmpty)
        #expect(store.transactionFeedPagesByKey.isEmpty)
        #expect(store.actionLogDiagnosticSnapshot == .empty)
        #expect(store.syncLane.scheduledFlushTask == nil)
        #expect(try await originalDatabase.fetchAccounts().first { $0.id == "checking" }?.name == "Daily Spending")
        #expect(try await originalDatabase.pendingLocalSyncMessageCount() == 1)
    }

    @Test func cancellationBeforeSubmissionDoesNotWrite() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await bundle.store.renameAccountAndRefresh(
                budgetID: "group-1", command: renameCommand
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let database = try #require(bundle.store.database)
        #expect(try await database.fetchAccounts().first { $0.id == "checking" }?.name == "Checking")
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        #expect(try await database.recentBudgetActions().isEmpty == true)
    }

    @Test func callerCancellationAfterCommitStillFinishesLocalRefresh() async throws {
        let (store, hook) = try await makeStoreWithFeedHook()
        hook.action = { [weak hook] in hook?.submission?.cancel() }
        let submission = Task {
            try await store.renameAccountAndRefresh(budgetID: "group-1", command: renameCommand)
        }
        hook.submission = submission
        let result = try await submission.value
        guard case .applied(let outcome) = result else {
            Issue.record("Post-commit cancellation must retain the durable outcome")
            return
        }
        #expect(submission.isCancelled)
        #expect(!outcome.refreshPending)
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?.accountNames["checking"] == "Daily Spending")
        #expect(store.actionLogDiagnosticSnapshot.count == 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") == 1)
    }

    private var renameCommand: AccountRenameCommand {
        AccountRenameCommand(
            accountID: "checking", expectedCurrentName: "Checking", newName: "Daily Spending"
        )
    }

    private func makeStoreWithFeedHook(
        additionalFixtureSQL: String = ""
    ) async throws -> (LocalFirstActualStore, FeedHook) {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: additionalFixtureSQL
        )
        let hook = FeedHook()
        let store = LocalFirstActualStore(
            keychain: bundle.keychain,
            fileManager: bundle.fileManager,
            transactionFeedPageReadHook: { _, _, _, _ in try hook.action?() }
        )
        _ = try await store.openCachedBudget(bundle.budget)
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        return (store, hook)
    }

    // The existing feed-read seam runs after the account commit. Synchronous
    // actions give these tests a deterministic boundary without waiter timeouts.
    @MainActor
    private final class FeedHook {
        var action: (@MainActor () throws -> Void)?
        var submission: Task<AccountLifecycleMutationResult, Error>?
    }
}
