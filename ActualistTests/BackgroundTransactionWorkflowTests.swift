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
        let settings = AppSettings(backgroundTransactionRefreshEnabled: false)

        if let projection = await workflow.prepare(
            isEnabled: settings.backgroundTransactionRefreshEnabled,
            settings: settings,
            budgetID: nil,
            store: makeThrowawayStore()
        ) {
            var prepared = settings
            workflow.applyPreparedProjection(projection, updatesBadge: false, to: &prepared)
        }

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

        if let projection = await workflow.prepare(
            isEnabled: settings.backgroundTransactionRefreshEnabled,
            settings: settings,
            budgetID: nil,
            store: makeThrowawayStore()
        ) {
            workflow.applyPreparedProjection(projection, updatesBadge: true, to: &settings)
        }

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

    @Test func applyingReviewOutcomeOnlyMutatesOwnedPendingProjection() {
        let (workflow, _) = makeWorkflow()
        var settings = AppSettings(
            localFirstServerURLString: "https://current.example",
            selectedBudgetID: "current-budget",
            backgroundTransactionRefreshEnabled: false
        )
        settings.pendingNewTransactionIDsByAccount["other-budget|checking"] = ["other-1"]
        let outcome = BackgroundTransactionWorkflow.PendingReviewOutcome(
            budgetID: "current-budget",
            projection: ["current-budget|checking": ["new-1"]],
            clearedCount: 0,
            scope: .account,
            pendingProjectionGeneration: 0
        )

        workflow.applyPendingReviewOutcome(outcome, to: &settings)

        #expect(settings.localFirstServerURLString == "https://current.example")
        #expect(settings.selectedBudgetID == "current-budget")
        #expect(!settings.backgroundTransactionRefreshEnabled)
        #expect(settings.pendingNewTransactionIDsByAccount["current-budget|checking"] == ["new-1"])
        #expect(settings.pendingNewTransactionIDsByAccount["other-budget|checking"] == ["other-1"])
    }

    @Test func sessionIdentityRejectsBudgetSwitchABA() {
        let (workflow, _) = makeWorkflow()
        let settings = AppSettings(
            localFirstServerURLString: "https://current.example",
            selectedBudgetID: "current-budget",
            selectedLocalFirstFileID: "current-file",
            selectedLocalFirstGroupID: "current-budget",
            backgroundTransactionRefreshEnabled: true
        )

        let beforeSwitch = workflow.sessionIdentity(settings: settings, recoveryIdentity: 4)
        let afterReturningToSameBudget = workflow.sessionIdentity(settings: settings, recoveryIdentity: 6)

        #expect(beforeSwitch != afterReturningToSameBudget)
    }

    @Test func applyingRefreshResultPreservesUnrelatedSettingsAndLogs() async throws {
        let pending = BackgroundPendingTransactions(accountID: "checking", transactionIDs: ["new-1"])
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(
            BackgroundTransactionRefreshResult(budgetID: "budget", accountCount: 1, pendingTransactions: [pending])
        )))
        let (workflow, _) = makeWorkflow(runner: runner, notificationPoster: { _, _, _ in })
        let initial = AppSettings(selectedBudgetID: "budget", backgroundTransactionRefreshEnabled: true)
        let result = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false, settings: initial,
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )
        var current = initial
        current.showHiddenCategories = true
        current.localFirstSyncDebug.totalEventCount = 7
        current.backgroundRefreshDebug.totalScheduleAttemptCount = 3

        workflow.applyRefreshResult(result, to: &current)

        #expect(current.showHiddenCategories)
        #expect(current.localFirstSyncDebug.totalEventCount == 7)
        #expect(current.backgroundRefreshDebug.totalScheduleAttemptCount == 3)
        #expect(current.pendingNewTransactionIDsByAccount["budget|checking"] == ["new-1"])
        #expect(current.backgroundRefreshDebug.recentRuns.first?.succeeded == true)
    }

    @Test func completedReviewPreventsOlderRefreshProjectionFromRestoringIDs() async {
        let (workflow, _) = makeWorkflow()
        _ = await workflow.prepare(
            isEnabled: false,
            settings: AppSettings(),
            budgetID: nil,
            store: makeThrowawayStore()
        )
        var refreshedSettings = AppSettings(selectedBudgetID: "budget")
        refreshedSettings.pendingNewTransactionIDsByAccount = ["budget|checking": ["new-1"]]
        let staleRefresh = BackgroundTransactionWorkflow.RefreshResult(
            outcome: .success,
            settings: refreshedSettings,
            runID: nil,
            budgetID: "budget",
            pendingProjectionGeneration: 0
        )
        var current = refreshedSettings
        workflow.applyPendingReviewOutcome(.init(
            budgetID: "budget",
            projection: [:],
            clearedCount: 1,
            scope: .account,
            pendingProjectionGeneration: 1
        ), to: &current)

        workflow.applyRefreshResult(staleRefresh, to: &current)

        #expect(current.pendingNewTransactionIDsByAccount.isEmpty)
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

    @Test func successfulNotificationRecordsSafeDetailedOutcome() async throws {
        let pending = BackgroundPendingTransactions(accountID: "private-account", transactionIDs: ["private-transaction"])
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(
            BackgroundTransactionRefreshResult(budgetID: "private-budget", accountCount: 1, pendingTransactions: [pending])
        )))
        var posted = 0
        let (workflow, _) = makeWorkflow(runner: runner, notificationPoster: { _, _, _ in posted += 1 })
        let output = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false,
            settings: AppSettings(backgroundTransactionRefreshEnabled: true),
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )
        let details = try #require(output.settings.backgroundRefreshDebug.recentRuns.first?.diagnosticDetails)
        #expect(posted == 1)
        #expect(details.alertsEnabled)
        #expect(details.serverInsertedCount == 1)
        #expect(details.notificationCandidateCount == 1)
        #expect(details.durablePendingIDCount == 1)
        #expect(details.notificationOutcome == .accepted)
    }

    @Test func failedNotificationRecordsFailureWithoutPersistingError() async throws {
        let pending = BackgroundPendingTransactions(accountID: "private-account", transactionIDs: ["private-transaction"])
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(
            BackgroundTransactionRefreshResult(budgetID: "private-budget", accountCount: 1, pendingTransactions: [pending])
        )))
        let (workflow, _) = makeWorkflow(
            runner: runner,
            notificationPoster: { _, _, _ in throw FakeRefreshError(message: "private host token=secret") }
        )
        let output = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false,
            settings: AppSettings(backgroundTransactionRefreshEnabled: true),
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(output.outcome == .success)
        #expect(run.succeeded == true)
        #expect(run.diagnosticDetails?.notificationOutcome == .failed)
        #expect(run.diagnosticDetails?.refreshOutcome == .succeeded)
        #expect(!run.message.contains("private host"))
        #expect(!String(describing: run.diagnosticDetails).contains("secret"))
    }

    @Test func failedPostRetriesSameDeterministicRequestIdentifier() async throws {
        let pendingStore = FakePendingTransactionStore()
        let pending = BackgroundPendingTransactions(accountID: "checking", transactionIDs: ["new-1"])
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(
            BackgroundTransactionRefreshResult(budgetID: "budget", accountCount: 1, pendingTransactions: [pending])
        )))
        var identifiers: [String] = []
        let (workflow, _) = makeWorkflow(
            runner: runner,
            pendingTransactionStore: pendingStore,
            notificationPoster: { _, identifier, _ in
                identifiers.append(identifier)
                if identifiers.count == 1 { throw FakeRefreshError(message: "not accepted") }
            }
        )
        let settings = AppSettings(backgroundTransactionRefreshEnabled: true)

        let first = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false, settings: settings,
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )
        let second = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false, settings: first.settings,
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )

        #expect(identifiers.count == 2)
        #expect(identifiers.first == identifiers.last)
        #expect(second.settings.backgroundRefreshDebug.recentRuns.first?.diagnosticDetails?.notificationOutcome == .accepted)
    }

    @Test func acceptedPostWithInterruptedAcknowledgementRetriesSameIdentifier() async throws {
        let pendingStore = FakePendingTransactionStore(ackFailuresRemaining: 1)
        let pending = BackgroundPendingTransactions(accountID: "checking", transactionIDs: ["new-1"])
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(
            BackgroundTransactionRefreshResult(budgetID: "budget", accountCount: 1, pendingTransactions: [pending])
        )))
        var identifiers: [String] = []
        let (workflow, _) = makeWorkflow(
            runner: runner,
            pendingTransactionStore: pendingStore,
            notificationPoster: { _, identifier, _ in identifiers.append(identifier) }
        )
        let settings = AppSettings(backgroundTransactionRefreshEnabled: true)
        let first = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false, settings: settings,
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )
        _ = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false, settings: first.settings,
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )

        #expect(identifiers.count == 2)
        #expect(identifiers.first == identifiers.last)
    }

    @Test func bankTimeoutIsRecordedWithoutRawErrorText() async throws {
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(
            BackgroundTransactionRefreshResult(budgetID: "budget", accountCount: 0, pendingTransactions: [])
        )))
        let (workflow, _) = makeWorkflow(
            runner: runner,
            bankSyncApplier: FakeBackgroundBankSyncApplier(
                result: .success(BankSyncBackgroundApplyResult(accountCount: 0, insertedTransactionIDsByAccount: [:])),
                delay: .seconds(30)
            ),
            bankSyncTimeoutSleep: { _ in throw BackgroundBankSyncStepError.timedOut }
        )
        let output = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false,
            settings: AppSettings(backgroundTransactionRefreshEnabled: true, simplefinBackgroundSyncEnabled: true),
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )
        let details = try #require(output.settings.backgroundRefreshDebug.recentRuns.first?.diagnosticDetails)
        #expect(details.bankOutcome == .timedOut)
        #expect(details.bankDurationMilliseconds != nil)
        #expect(!output.settings.backgroundRefreshDebug.recentRuns[0].message.contains("private"))
    }

    @Test func bankFailureIsRecordedWithoutPersistingErrorText() async throws {
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(
            BackgroundTransactionRefreshResult(budgetID: "budget", accountCount: 0, pendingTransactions: [])
        )))
        let (workflow, _) = makeWorkflow(
            runner: runner,
            bankSyncApplier: FakeBackgroundBankSyncApplier(result: .failure(FakeRefreshError(message: "private account secret")))
        )
        let output = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false,
            settings: AppSettings(backgroundTransactionRefreshEnabled: true, simplefinBackgroundSyncEnabled: true),
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeThrowawayStore()
        )
        let details = try #require(output.settings.backgroundRefreshDebug.recentRuns.first?.diagnosticDetails)
        #expect(details.bankOutcome == .failed)
        #expect(!output.settings.backgroundRefreshDebug.recentRuns[0].message.contains("private account secret"))
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

        #expect(output.outcome == .failed(SafeSyncDiagnostic.genericFailure))
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == false)
        #expect(run.message == SafeSyncDiagnostic.genericFailure)
    }

    @Test func unavailableBackgroundCredentialSkipsWithoutClearingPreferences() async throws {
        let backend = FakeKeychainBackend()
        let keychain = makeKeychain(backend: backend)
        try keychain.saveActualSyncToken("synthetic-token")
        backend.copyFailureStatus = errSecInteractionNotAllowed
        let store = LocalFirstActualStore(keychain: keychain)
        // This test isolates credential preflight behavior. It intentionally
        // gives the runner the full synthetic one-second budget rather than
        // exercising the separately covered production completion reserve.
        let (workflow, _) = makeWorkflow(
            runner: BackgroundTransactionRefreshRunner(),
            completionTimeReserve: .zero
        )
        var settings = AppSettings(backgroundTransactionRefreshEnabled: true)
        settings.selectedBudgetID = "group-1"
        settings.localFirstServerURLString = "https://synthetic.invalid"

        let output = await workflow.performRefresh(
            timeLimit: .seconds(1), isDemoMode: false,
            settings: settings, selectedBudget: nil, budgets: [],
            hasSyncCredentials: false, store: store
        )
        #expect(output.outcome == .success)
        #expect(output.settings.backgroundTransactionRefreshEnabled)
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.message == "Skipped: credentials unavailable on this device")
        #expect(SafeSyncDiagnostic.backgroundMessage(run.message, succeeded: run.succeeded)
            == "Skipped: credentials unavailable on this device")
        backend.copyFailureStatus = nil
        #expect(try keychain.readActualSyncToken() == "synthetic-token")
    }

    // MARK: Helpers

    private func makeWorkflow(
        authorizationRequester: @escaping @MainActor () async throws -> Bool = { true },
        badgeUpdater: @escaping @MainActor (Int) -> Void = { _ in },
        settingsStore: AppSettingsStore? = nil,
        runner: (any BackgroundTransactionRefreshing)? = nil,
        bankSyncApplier: (any BackgroundBankSyncApplying)? = nil,
        bankSyncTimeoutSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        completionTimeReserve: Duration = .seconds(2),
        pendingTransactionStore: (any BackgroundPendingTransactionPersisting)? = nil,
        notificationPoster: (@MainActor (String, String, Int) async throws -> Void)? = nil
    ) -> (BackgroundTransactionWorkflow, AppSettingsStore) {
        let store = settingsStore ?? makeSettingsStore()
        let workflow = BackgroundTransactionWorkflow(
            settingsStore: store,
            bankSyncTimeoutSleep: bankSyncTimeoutSleep,
            notificationAuthorizationRequester: authorizationRequester,
            applicationBadgeUpdater: badgeUpdater,
            runner: runner,
            bankSyncApplier: bankSyncApplier,
            completionTimeReserve: completionTimeReserve,
            pendingTransactionStore: pendingTransactionStore ?? FakePendingTransactionStore(),
            notificationPoster: notificationPoster
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
private final class FakePendingTransactionStore: BackgroundPendingTransactionPersisting {
    private var idsByAccount: [String: [String]] = [:]
    private var delivery: LocalFirstActualStore.PendingNewTransactionDelivery?
    private var ackFailuresRemaining: Int

    init(ackFailuresRemaining: Int = 0) {
        self.ackFailuresRemaining = ackFailuresRemaining
    }

    func reconcilePendingNewTransactionProjection(
        budgetID: String,
        legacyStorage: [String: [String]]
    ) async throws -> [String: [String]] {
        var result = legacyStorage.filter { !$0.key.hasPrefix("\(budgetID)|") }
        for (accountID, ids) in idsByAccount {
            result["\(budgetID)|\(accountID)"] = ids
        }
        return result
    }

    func registerRemotePendingNewTransactions(
        _ pending: [BackgroundPendingTransactions],
        budgetID: String,
        notificationID: String
    ) async throws {
        for item in pending {
            idsByAccount[item.accountID, default: []].append(contentsOf: item.transactionIDs)
            idsByAccount[item.accountID] = Array(Set(idsByAccount[item.accountID] ?? [])).sorted()
        }
        let ids = idsByAccount.values.flatMap { $0 }.sorted()
        if !ids.isEmpty, delivery == nil {
            delivery = .init(
                requestIdentifier: "actualist.new-transactions.\(notificationID)",
                transactionIDs: ids
            )
        }
    }

    func pendingNewTransactionDelivery(
        budgetID: String
    ) async throws -> LocalFirstActualStore.PendingNewTransactionDelivery? { delivery }

    func acknowledgePendingNewTransactionDelivery(
        _ delivery: LocalFirstActualStore.PendingNewTransactionDelivery,
        budgetID: String
    ) async throws {
        if ackFailuresRemaining > 0 {
            ackFailuresRemaining -= 1
            throw FakeRefreshError(message: "acknowledgement interrupted")
        }
        self.delivery = nil
    }

    func suppressPendingNewTransactionDeliveries(budgetID: String) async throws {
        delivery = nil
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
        openBudget: BackgroundBudgetOpener?,
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

@MainActor
private struct FakeBackgroundBankSyncApplier: BackgroundBankSyncApplying {
    let result: Result<BankSyncBackgroundApplyResult, Error>
    var delay: Duration = .zero

    func backgroundBankSyncApply(request: BankSyncBackgroundApplyRequest) async throws -> BankSyncBackgroundApplyResult {
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}
