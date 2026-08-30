import Foundation
import Testing
@testable import Actualist

/// Phase 6 workflow tests: the toggle semantics — either toggle schedules
/// the task, only the alerts toggle notifies, only-alerts mode never
/// touches SimpleFIN, and a SimpleFIN failure or timeout never fails the
/// parent refresh.
@MainActor
struct BackgroundBankSyncWorkflowTests {
    private let service = "com.sporez.actualist.tests"

    // MARK: Fakes

    @MainActor
    private final class FakeApplier: BackgroundBankSyncApplying {
        private(set) var callCount = 0
        private(set) var lastBudgetID: String?
        let result: Result<BankSyncBackgroundApplyResult, Error>

        init(result: Result<BankSyncBackgroundApplyResult, Error>) {
            self.result = result
        }

        func backgroundBankSyncApply(budgetID: String) async throws -> BankSyncBackgroundApplyResult {
            callCount += 1
            lastBudgetID = budgetID
            return try result.get()
        }
    }

    @MainActor
    private final class CapturingRunner: BackgroundTransactionRefreshing {
        private(set) var receivedTimeLimit: Duration?

        func run(
            settings: AppSettings,
            selectedBudget: ActualBudget?,
            budgets: [ActualBudget],
            hasSyncCredentials: Bool,
            store: LocalFirstActualStore,
            timeLimit: Duration
        ) async throws -> BackgroundTransactionRefreshOutcome {
            receivedTimeLimit = timeLimit
            return .synced(BackgroundTransactionRefreshResult(
                budgetID: "group-1",
                accountCount: 1,
                pendingTransactions: []
            ))
        }
    }

    @MainActor
    private final class SleepingApplier: BackgroundBankSyncApplying {
        let sleep: Duration

        init(sleep: Duration) {
            self.sleep = sleep
        }

        func backgroundBankSyncApply(budgetID: String) async throws -> BankSyncBackgroundApplyResult {
            try await Task.sleep(for: sleep)
            return BankSyncBackgroundApplyResult(accountCount: 1, insertedTransactionIDsByAccount: [:])
        }
    }

    private func makeSettings(
        alerts: Bool = false,
        backgroundBankSync: Bool = false,
        experimentalBankSync: Bool? = nil
    ) -> AppSettings {
        var settings = AppSettings()
        settings.backgroundTransactionRefreshEnabled = alerts
        settings.simplefinBackgroundSyncEnabled = backgroundBankSync
        if experimentalBankSync ?? backgroundBankSync {
            settings.enabledExperimentalFeatures = [.bankSync]
        }
        return settings
    }

    private func syncedResult(
        pending: [BackgroundPendingTransactions] = []
    ) -> BackgroundTransactionRefreshResult {
        BackgroundTransactionRefreshResult(
            budgetID: "group-1",
            accountCount: 1,
            pendingTransactions: pending
        )
    }

    private func makeWorkflow(
        settingsStore: AppSettingsStore? = nil,
        runner: (any BackgroundTransactionRefreshing)? = nil,
        applier: (any BackgroundBankSyncApplying)? = nil,
        bankSyncTimeLimit: Duration = .seconds(5),
        badgeUpdates: @escaping @MainActor (Int) -> Void = { _ in }
    ) -> BackgroundTransactionWorkflow {
        BackgroundTransactionWorkflow(
            settingsStore: settingsStore ?? {
                let defaults = UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)")!
                return AppSettingsStore(defaults: defaults)
            }(),
            notificationAuthorizationRequester: { true },
            applicationBadgeUpdater: badgeUpdates,
            runner: runner ?? FakeBackgroundTransactionRefreshRunner(
                result: .success(.synced(syncedResult()))
            ),
            bankSyncApplier: applier,
            bankSyncTimeLimit: bankSyncTimeLimit
        )
    }

    private func makeStore() -> LocalFirstActualStore {
        LocalFirstActualStore(
            keychain: KeychainStore(
                service: service,
                account: UUID().uuidString,
                simplefinAccessKeyAccount: UUID().uuidString
            )
        )
    }

    // MARK: Shared deadline

    @Test func bankSyncReserveIsSubtractedFromTheSingleWakeBudget() async {
        let runner = CapturingRunner()
        let applier = FakeApplier(result: .success(BankSyncBackgroundApplyResult(
            accountCount: 0,
            insertedTransactionIDsByAccount: [:]
        )))
        let workflow = makeWorkflow(runner: runner, applier: applier)
        let settings = makeSettings(backgroundBankSync: true)

        _ = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        // Test workflow reserves its injected 5-second bank window and the
        // production 2-second finalization window from the 25-second wake.
        #expect(runner.receivedTimeLimit == .seconds(18))
    }

    // MARK: Toggle semantics

    @Test func onlyAlertsToggleNeverTouchesSimpleFIN() async throws {
        let applier = FakeApplier(result: .success(BankSyncBackgroundApplyResult(
            accountCount: 1,
            insertedTransactionIDsByAccount: ["savings": ["tx-1"]]
        )))
        let workflow = makeWorkflow(applier: applier)
        let settings = makeSettings(alerts: true, backgroundBankSync: false)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        #expect(output.outcome == .success)
        #expect(applier.callCount == 0)
    }

    @Test func experimentalBankSyncOffNeverTouchesSimpleFINWhenAlertsAreOn() async throws {
        var badgeCalls: [Int] = []
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(syncedResult(
            pending: [BackgroundPendingTransactions(accountID: "checking", transactionIDs: ["sync-1"])]
        ))))
        let applier = FakeApplier(result: .success(BankSyncBackgroundApplyResult(
            accountCount: 1,
            insertedTransactionIDsByAccount: ["savings": ["bank-1"]]
        )))
        let workflow = makeWorkflow(
            runner: runner,
            applier: applier,
            badgeUpdates: { badgeCalls.append($0) }
        )
        let settings = makeSettings(
            alerts: true,
            backgroundBankSync: true,
            experimentalBankSync: false
        )

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        #expect(output.outcome == .success)
        #expect(applier.callCount == 0)
        #expect(output.settings.pendingNewTransactionIDsByAccount["group-1|checking"] == ["sync-1"])
        #expect(badgeCalls == [1])
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(!run.message.contains("bank sync"))
    }

    @Test func experimentalBankSyncOffDoesNotReserveBankWindowFromAlertsWake() async {
        let runner = CapturingRunner()
        let applier = FakeApplier(result: .success(BankSyncBackgroundApplyResult(
            accountCount: 0,
            insertedTransactionIDsByAccount: [:]
        )))
        let workflow = makeWorkflow(runner: runner, applier: applier)
        let settings = makeSettings(
            alerts: true,
            backgroundBankSync: true,
            experimentalBankSync: false
        )

        _ = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        // Alerts keep the full non-bank window (25 - 2 completion = 23).
        #expect(runner.receivedTimeLimit == .seconds(23))
        #expect(applier.callCount == 0)
    }

    @Test func simplefinOnlyAppliesSilentlyWithoutNotificationsOrPendingIDs() async throws {
        var badgeCalls: [Int] = []
        let applier = FakeApplier(result: .success(BankSyncBackgroundApplyResult(
            accountCount: 1,
            insertedTransactionIDsByAccount: ["savings": ["tx-1", "tx-2"]]
        )))
        let workflow = makeWorkflow(
            applier: applier,
            badgeUpdates: { badgeCalls.append($0) }
        )
        let settings = makeSettings(alerts: false, backgroundBankSync: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        #expect(output.outcome == .success)
        #expect(applier.callCount == 1)
        #expect(applier.lastBudgetID == "group-1")
        // Silent: no pending-ID record, no badge.
        #expect(output.settings.pendingNewTransactionIDsByAccount.isEmpty)
        #expect(badgeCalls.isEmpty)
        // Step recorded in the debug run.
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.message.contains("bank sync: 1 account, 2 added in "))
    }

    @Test func bothTogglesCombineSyncAndBankInsertsIntoOneNotificationPass() async throws {
        var badgeCalls: [Int] = []
        let runner = FakeBackgroundTransactionRefreshRunner(result: .success(.synced(syncedResult(
            pending: [BackgroundPendingTransactions(accountID: "checking", transactionIDs: ["sync-1"])]
        ))))
        let applier = FakeApplier(result: .success(BankSyncBackgroundApplyResult(
            accountCount: 1,
            insertedTransactionIDsByAccount: ["savings": ["bank-1"]]
        )))
        let workflow = makeWorkflow(
            runner: runner,
            applier: applier,
            badgeUpdates: { badgeCalls.append($0) }
        )
        let settings = makeSettings(alerts: true, backgroundBankSync: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        #expect(output.outcome == .success)
        // Both the sync pull and the bank apply feed the same pending set.
        #expect(output.settings.pendingNewTransactionIDsByAccount["group-1|checking"] == ["sync-1"])
        #expect(output.settings.pendingNewTransactionIDsByAccount["group-1|savings"] == ["bank-1"])
        #expect(badgeCalls == [2])
    }

    @Test func simplefinFailureNeverFailsTheParentRefresh() async throws {
        let applier = FakeApplier(result: .failure(ActualAPIError.transport(URLError.Code.timedOut)))
        let workflow = makeWorkflow(applier: applier)
        let settings = makeSettings(alerts: true, backgroundBankSync: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        #expect(output.outcome == .success)
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == true)
        #expect(run.message.contains("bank sync failed"))
    }

    @Test func taskExpirationCancellationIsNotSwallowedByBankSync() async {
        let applier = FakeApplier(result: .failure(CancellationError()))
        let workflow = makeWorkflow(applier: applier)
        let settings = makeSettings(alerts: true, backgroundBankSync: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        #expect(output.outcome == .cancelled)
    }

    @Test func simplefinTimeoutNeverFailsTheParentRefresh() async throws {
        let applier = SleepingApplier(sleep: .seconds(2))
        let workflow = makeWorkflow(
            applier: applier,
            bankSyncTimeLimit: .milliseconds(50)
        )
        let settings = makeSettings(alerts: true, backgroundBankSync: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        #expect(output.outcome == .success)
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == true)
        #expect(run.message.contains("bank sync timed out"))
    }

    @Test func skippedRunnerDoesNotRunSimpleFIN() async throws {
        let runner = FakeBackgroundTransactionRefreshRunner(
            result: .success(.skipped("Skipped: sync credentials missing"))
        )
        let applier = FakeApplier(result: .success(BankSyncBackgroundApplyResult(
            accountCount: 0,
            insertedTransactionIDsByAccount: [:]
        )))
        let workflow = makeWorkflow(runner: runner, applier: applier)
        let settings = makeSettings(alerts: false, backgroundBankSync: true)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25),
            isDemoMode: false,
            settings: settings,
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: false,
            store: makeStore()
        )

        #expect(output.outcome == .success)
        #expect(applier.callCount == 0)
    }
}

@MainActor
private final class FakeBackgroundTransactionRefreshRunner: BackgroundTransactionRefreshing {
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
        try result.get()
    }
}
