import Foundation
import Security
import Testing
@testable import Actualist

/// Focused tests for `BackgroundTransactionWorkflow` outcome mapping.
///
/// The full refresh run (success/timeout/cold-open) is exercised end-to-end
/// through the AppState composer in `AppStateBackgroundRefreshTests`, so this
/// suite targets the pure outcome logic that does not require a real budget
/// sync: enablement, preparation, pending-ID lookup/clearing, the shared badge
/// source of truth, schedule-attempt recording, and demo-mode no-op.
@MainActor
struct BackgroundTransactionWorkflowTests {
    private static let service = "com.sporez.actualist.tests"

    // MARK: Enablement

    @Test func enablingWhenAuthorizedAndCredentialsPromoteReturnsEnabled() async throws {
        let backend = FakeKeychainBackend()
        let keychain = makeKeychain(backend: backend)
        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(Data([1, 2, 3]), fileID: "file-1", keyID: "key-1")

        let (workflow, _) = makeWorkflow()

        let outcome = await workflow.enable(true, keychain: keychain)

        #expect(outcome == .enabled)
        for item in backend.storedItemAttributes(service: Self.service) {
            #expect(
                item[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
        }
    }

    @Test func enablingWhenAuthorizationDeniedReturnsAuthorizationDenied() async {
        let keychain = makeKeychain()
        let (workflow, _) = makeWorkflow(authorizationRequester: { false })

        let outcome = await workflow.enable(true, keychain: keychain)

        #expect(outcome == .authorizationDenied)
    }

    @Test func enablingWhenCredentialPromotionFailsReturnsCredentialPromotionFailed() async throws {
        let backend = FakeKeychainBackend()
        let keychain = makeKeychain(backend: backend)
        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(Data([1, 2, 3]), fileID: "file-1", keyID: "key-1")
        backend.updateFailureStatus = errSecAuthFailed

        let (workflow, _) = makeWorkflow()

        let outcome = await workflow.enable(true, keychain: keychain)

        let expectedMessage = LocalFirstError.keychainFailure(
            "promote credentials for background refresh",
            errSecAuthFailed
        ).localizedDescription
        #expect(outcome == .credentialPromotionFailed(expectedMessage))
    }

    @Test func disablingReturnsDisabledWithoutPromotingCredentials() async throws {
        let backend = FakeKeychainBackend()
        let keychain = makeKeychain(backend: backend)
        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(Data([1, 2, 3]), fileID: "file-1", keyID: "key-1")
        // Saving the items upserts via `update`; reset so the count isolates a
        // promotion attempt from the enable path under test.
        backend.resetUpdateCallCount()

        let (workflow, _) = makeWorkflow()

        let outcome = await workflow.enable(false, keychain: keychain)

        #expect(outcome == .disabled)
        #expect(backend.updateCallCount == 0)
    }

    // MARK: Preparation

    @Test func prepareWhenDisabledIsNoOp() async throws {
        var authorizationRequestCount = 0
        var badgeCounts: [Int] = []
        let (workflow, _) = makeWorkflow(
            authorizationRequester: {
                authorizationRequestCount += 1
                return true
            },
            badgeUpdater: { badgeCounts.append($0) }
        )
        var settings = AppSettings(backgroundTransactionRefreshEnabled: false)

        await workflow.prepare(isEnabled: settings.backgroundTransactionRefreshEnabled, settings: settings)

        #expect(authorizationRequestCount == 0)
        #expect(badgeCounts.isEmpty)
    }

    @Test func prepareWhenEnabledRequestsAuthorizationAndUpdatesBadge() async throws {
        var authorizationRequestCount = 0
        var badgeCounts: [Int] = []
        let (workflow, _) = makeWorkflow(
            authorizationRequester: {
                authorizationRequestCount += 1
                return true
            },
            badgeUpdater: { badgeCounts.append($0) }
        )
        var settings = AppSettings(backgroundTransactionRefreshEnabled: true)
        settings.pendingNewTransactionIDsByAccount = [
            "budget|checking": ["txn-1", "txn-2"]
        ]

        await workflow.prepare(isEnabled: settings.backgroundTransactionRefreshEnabled, settings: settings)

        #expect(authorizationRequestCount == 1)
        #expect(badgeCounts == [2])
    }

    // MARK: Pending new-transaction IDs

    @Test func pendingIDsByBudgetAndAccountReturnOnlyThatAccount() {
        let (workflow, _) = makeWorkflow()
        let settings = makeSettings(
            pendingNewTransactionIDsByAccount: [
                "budget|checking": ["txn-1", "txn-2"],
                "budget|credit": ["txn-3"],
                "other|checking": ["txn-4"]
            ]
        )

        let ids = workflow.pendingNewTransactionIDs(
            budgetID: "budget",
            accountID: "checking",
            in: settings
        )

        #expect(ids == Set(["txn-1", "txn-2"]))
    }

    @Test func pendingIDsByBudgetAggregateAcrossAccounts() {
        let (workflow, _) = makeWorkflow()
        let settings = makeSettings(
            pendingNewTransactionIDsByAccount: [
                "budget|checking": ["txn-1", "txn-2"],
                "budget|credit": ["txn-2", "txn-3"],
                "other|checking": ["txn-4"]
            ]
        )

        let ids = workflow.pendingNewTransactionIDs(budgetID: "budget", in: settings)

        #expect(ids == Set(["txn-1", "txn-2", "txn-3"]))
    }

    @Test func clearingPendingIDsByAccountUpdatesBadgeAndPersists() {
        var badgeCounts: [Int] = []
        let (workflow, store) = makeWorkflow(badgeUpdater: { badgeCounts.append($0) })
        var settings = makeSettings(
            pendingNewTransactionIDsByAccount: [
                "budget|checking": ["txn-1", "txn-2"],
                "budget|credit": ["txn-3"]
            ]
        )

        workflow.clearPendingNewTransactionIDs(budgetID: "budget", accountID: "checking", in: &settings)

        #expect(settings.pendingNewTransactionIDsByAccount["budget|checking"] == nil)
        #expect(settings.pendingNewTransactionIDsByAccount["budget|credit"] == ["txn-3"])
        #expect(badgeCounts == [1])
        #expect(
            store.load().pendingNewTransactionIDsByAccount["budget|checking"] == nil
        )
    }

    @Test func clearingLastAccountPendingIDsClearsApplicationBadge() {
        var badgeCounts: [Int] = []
        let (workflow, _) = makeWorkflow(badgeUpdater: { badgeCounts.append($0) })
        var settings = makeSettings(
            pendingNewTransactionIDsByAccount: [
                "budget|checking": ["txn-1", "txn-2"]
            ]
        )

        workflow.clearPendingNewTransactionIDs(budgetID: "budget", accountID: "checking", in: &settings)

        #expect(settings.pendingNewTransactionIDsByAccount.isEmpty)
        #expect(badgeCounts == [0])
    }

    @Test func clearingPendingIDsByBudgetClearsEveryAccountInBudgetOnly() {
        var badgeCounts: [Int] = []
        let (workflow, store) = makeWorkflow(badgeUpdater: { badgeCounts.append($0) })
        var settings = makeSettings(
            pendingNewTransactionIDsByAccount: [
                "budget|checking": ["txn-1"],
                "budget|credit": ["txn-2"],
                "other|checking": ["txn-3"]
            ]
        )

        workflow.clearPendingNewTransactionIDs(budgetID: "budget", in: &settings)

        #expect(settings.pendingNewTransactionIDsByAccount["budget|checking"] == nil)
        #expect(settings.pendingNewTransactionIDsByAccount["budget|credit"] == nil)
        #expect(settings.pendingNewTransactionIDsByAccount["other|checking"] == ["txn-3"])
        #expect(badgeCounts == [1])
        #expect(
            store.load().pendingNewTransactionIDsByAccount["other|checking"] == ["txn-3"]
        )
    }

    @Test func updateApplicationBadgeReflectsDeduplicatedPendingCount() {
        var badgeCounts: [Int] = []
        let (workflow, _) = makeWorkflow(badgeUpdater: { badgeCounts.append($0) })
        let settings = makeSettings(
            pendingNewTransactionIDsByAccount: [
                "budget|checking": ["txn-1", "txn-2"],
                "budget|credit": ["txn-2", "txn-3"]
            ]
        )

        let count = workflow.updateApplicationBadge(in: settings)

        #expect(count == 3)
        #expect(badgeCounts == [3])
    }

    // MARK: Schedule-attempt recording

    @Test func recordingScheduleAttemptPersistsIntoDebugHistory() throws {
        let (workflow, store) = makeWorkflow()
        var settings = AppSettings()
        let earliest = Date(timeIntervalSince1970: 1_700_000_000)

        workflow.recordScheduleAttempt(
            succeeded: true,
            earliestBeginDate: earliest,
            message: "Scheduled background refresh",
            in: &settings
        )

        let loaded = store.load()
        #expect(loaded.backgroundRefreshDebug.totalScheduleAttemptCount == 1)
        let attempt = try #require(loaded.backgroundRefreshDebug.recentScheduleAttempts.first)
        #expect(attempt.succeeded)
        #expect(attempt.earliestBeginDate == earliest)
        #expect(attempt.message == "Scheduled background refresh")
    }

    // MARK: Refresh execution — demo no-op

    @Test func performRefreshInDemoModeSkipsWithoutRecordingARun() async {
        let (workflow, _) = makeWorkflow()
        let settings = AppSettings(backgroundTransactionRefreshEnabled: true)
        let store = LocalFirstActualStore(
            keychain: KeychainStore(
                service: Self.service,
                account: UUID().uuidString
            )
        )

        let result = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: true,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: false,
            store: store
        )

        #expect(result.outcome == .skipped)
        #expect(result.settings.backgroundRefreshDebug.recentRuns.isEmpty)
        #expect(result.settings.backgroundRefreshDebug.totalWakeCount == 0)
    }

    // MARK: Refresh execution — outcome mapping

    @Test func performRefreshReturningSyncedWithNoNewTransactionsSucceedsAndRecordsRunnerMessage() async throws {
        let synced = BackgroundTransactionRefreshResult(
            budgetID: "budget",
            accountCount: 2,
            pendingTransactions: []
        )
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(synced)))
        let (workflow, _) = makeWorkflow(runner: runner)
        let settings = AppSettings(backgroundTransactionRefreshEnabled: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeThrowawayStore()
        )

        #expect(output.outcome == .success)
        #expect(runner.callCount == 1)
        #expect(runner.lastHasSyncCredentials == true)
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == true)
        #expect(run.message == synced.completionMessage)
        // No new transactions: pending IDs are not recorded.
        #expect(output.settings.pendingNewTransactionIDsByAccount.isEmpty)
    }

    @Test func performRefreshWhereRunnerSkipsStillSucceedsAndRecordsSkipMessage() async throws {
        let skipMessage = "Skipped: alerts disabled, no selected budget"
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.skipped(skipMessage)))
        let (workflow, _) = makeWorkflow(runner: runner)
        let settings = AppSettings(backgroundTransactionRefreshEnabled: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: false,
            store: makeThrowawayStore()
        )

        // A runner-side skip is a successful completion from the workflow's
        // perspective; only demo mode maps to RefreshOutcome.skipped before the
        // runner even runs.
        #expect(output.outcome == .success)
        #expect(runner.callCount == 1)
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == true)
        #expect(run.message == skipMessage)
    }

    @Test func performRefreshCancelledDuringSyncMapsToCancelledOutcome() async throws {
        let runner = FakeBackgroundTransactionRefreshRunner(result: .failure(CancellationError()))
        let (workflow, _) = makeWorkflow(runner: runner)
        let settings = AppSettings(backgroundTransactionRefreshEnabled: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeThrowawayStore()
        )

        #expect(output.outcome == .cancelled)
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == false)
        #expect(run.message == "Cancelled")
    }

    @Test func performRefreshExceedingTimeLimitMapsToTimedOutOutcome() async throws {
        let runner = FakeBackgroundTransactionRefreshRunner(
            result: .failure(BackgroundTransactionRefreshRunnerError.timeLimitExceeded)
        )
        let (workflow, _) = makeWorkflow(runner: runner)
        let settings = AppSettings(backgroundTransactionRefreshEnabled: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeThrowawayStore()
        )

        #expect(output.outcome == .timedOut)
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == false)
        #expect(run.message == "Timed out")
    }

    @Test func performRefreshThrowingSyncErrorMapsToFailedOutcomeWithMessage() async throws {
        let runner = FakeBackgroundTransactionRefreshRunner(
            result: .failure(FakeRefreshError(message: "Sync transport unreachable"))
        )
        let (workflow, _) = makeWorkflow(runner: runner)
        let settings = AppSettings(backgroundTransactionRefreshEnabled: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeThrowawayStore()
        )

        #expect(output.outcome == .failed("Sync transport unreachable"))
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == false)
        #expect(run.message == "Sync transport unreachable")
    }

    // MARK: Helpers

    private func makeWorkflow(
        authorizationRequester: @escaping @MainActor () async throws -> Bool = { true },
        badgeUpdater: @escaping @MainActor (Int) -> Void = { _ in },
        settingsStore: AppSettingsStore? = nil,
        runner: (any BackgroundTransactionRefreshing)? = nil
    ) -> (BackgroundTransactionWorkflow, AppSettingsStore) {
        let store = settingsStore ?? makeSettingsStore()
        let workflow = BackgroundTransactionWorkflow(
            settingsStore: store,
            notificationAuthorizationRequester: authorizationRequester,
            applicationBadgeUpdater: badgeUpdater,
            runner: runner
        )
        return (workflow, store)
    }

    private func makeSettingsStore() -> AppSettingsStore {
        let defaults = UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)")!
        return AppSettingsStore(defaults: defaults)
    }

    private func makeThrowawayStore() -> LocalFirstActualStore {
        LocalFirstActualStore(
            keychain: KeychainStore(
                service: Self.service,
                account: UUID().uuidString
            )
        )
    }

    private func makeKeychain(backend: FakeKeychainBackend = FakeKeychainBackend()) -> KeychainStore {
        KeychainStore(
            service: Self.service,
            account: "actual-sync-token",
            backend: backend
        )
    }

    private func makeSettings(
        pendingNewTransactionIDsByAccount: [String: [String]]
    ) -> AppSettings {
        var settings = AppSettings()
        settings.pendingNewTransactionIDsByAccount = pendingNewTransactionIDsByAccount
        return settings
    }
}

@MainActor
private final class FakeBackgroundTransactionRefreshRunner: BackgroundTransactionRefreshing {
    private(set) var callCount = 0
    private(set) var lastHasSyncCredentials: Bool?
    private(set) var lastTimeLimit: Duration?
    private let result: Result<BackgroundTransactionRefreshOutcome, Error>

    init(result: Result<BackgroundTransactionRefreshOutcome, Error>) {
        self.result = result
    }

    func run(
        settings: AppSettings,
        selectedBudget: ActualBudget?,
        budgets: [ActualBudget],
        hasSyncCredentials: Bool,
        store: LocalFirstActualStore,
        timeLimit: Duration
    ) async throws -> BackgroundTransactionRefreshOutcome {
        callCount += 1
        lastHasSyncCredentials = hasSyncCredentials
        lastTimeLimit = timeLimit
        return try result.get()
    }
}

private struct FakeRefreshError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
