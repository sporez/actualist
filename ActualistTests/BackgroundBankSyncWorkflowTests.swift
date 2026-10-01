import Foundation
import Testing
@testable import Actualist

/// Background workflow tests: the toggle semantics — either toggle schedules
/// the task, only the alerts toggle notifies, only-alerts mode never
/// touches SimpleFIN, and a SimpleFIN failure or timeout never fails the
/// parent refresh.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct BackgroundBankSyncWorkflowTests {
    private let service = "com.sporez.actualist.tests"

    // MARK: Fakes

    @MainActor
    private final class FakeApplier: BackgroundBankSyncApplying {
        private(set) var callCount = 0
        private(set) var lastBudgetID: String?
        let result: Result<BankSyncBackgroundApplyResult, Error>
        let onApply: @MainActor (BankSyncBackgroundApplyRequest) -> Void

        init(
            result: Result<BankSyncBackgroundApplyResult, Error>,
            onApply: @escaping @MainActor (BankSyncBackgroundApplyRequest) -> Void = { _ in }
        ) {
            self.result = result
            self.onApply = onApply
        }

        func backgroundBankSyncApply(request: BankSyncBackgroundApplyRequest) async throws -> BankSyncBackgroundApplyResult {
            callCount += 1
            lastBudgetID = request.budgetID
            onApply(request)
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
        let delay = ManualTestDelay()

        func backgroundBankSyncApply(request: BankSyncBackgroundApplyRequest) async throws -> BankSyncBackgroundApplyResult {
            try await delay.sleep(for: .seconds(2))
            return BankSyncBackgroundApplyResult(accountCount: 1, insertedTransactionIDsByAccount: [:])
        }
    }

    @MainActor
    private final class SuspendedCommitApplier: BackgroundBankSyncApplying {
        let delay = ManualTestDelay()
        let pendingStore: BankWorkflowPendingStore

        init(pendingStore: BankWorkflowPendingStore) {
            self.pendingStore = pendingStore
        }

        func backgroundBankSyncApply(request: BankSyncBackgroundApplyRequest) async throws -> BankSyncBackgroundApplyResult {
            try await delay.sleep(for: .seconds(2))
            pendingStore.commit(["savings": ["late-bank-1"]], notificationID: request.notificationID)
            return BankSyncBackgroundApplyResult(
                accountCount: 1,
                insertedTransactionIDsByAccount: ["savings": ["late-bank-1"]]
            )
        }
    }

    private func makeSettings(
        alerts: Bool = false,
        backgroundBankSync: Bool = false
    ) -> AppSettings {
        var settings = AppSettings()
        settings.backgroundTransactionRefreshEnabled = alerts
        settings.simplefinBackgroundSyncEnabled = backgroundBankSync
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
        timer: ManualTestDelay = ManualTestDelay(),
        badgeUpdates: @escaping @MainActor (Int) -> Void = { _ in },
        pendingStore: (any BackgroundPendingTransactionPersisting)? = nil,
        notificationPoster: (@MainActor (String, String, Int) async throws -> Void)? = nil
    ) -> BackgroundTransactionWorkflow {
        BackgroundTransactionWorkflow(
            settingsStore: settingsStore ?? {
                let defaults = UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)")!
                return AppSettingsStore(defaults: defaults)
            }(),
            bankSyncTimeoutSleep: { try await timer.sleep(for: $0) },
            notificationAuthorizationRequester: { true },
            applicationBadgeUpdater: badgeUpdates,
            runner: runner ?? FakeBackgroundTransactionRefreshRunner(
                result: .success(.synced(syncedResult()))
            ),
            bankSyncApplier: applier,
            pendingTransactionStore: pendingStore ?? BankWorkflowPendingStore(),
            notificationPoster: notificationPoster
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

        // Server and bank work share the 23-second absolute work deadline.
        #expect(runner.receivedTimeLimit.map { $0 > .seconds(22) && $0 <= .seconds(23) } == true)
    }

    @Test func shorterThanCompletionReserveTimesOutWithoutExtendingBudget() async {
        let runner = CapturingRunner()
        let workflow = makeWorkflow(runner: runner)

        let output = await workflow.performRefresh(
            timeLimit: .seconds(1),
            isDemoMode: false,
            settings: makeSettings(alerts: true),
            selectedBudget: nil,
            budgets: [],
            hasSyncCredentials: true,
            store: makeStore()
        )

        #expect(output.outcome == .timedOut)
        #expect(runner.receivedTimeLimit == nil)
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
        let pendingStore = BankWorkflowPendingStore()
        let applier = FakeApplier(result: .success(BankSyncBackgroundApplyResult(
            accountCount: 1,
            insertedTransactionIDsByAccount: ["savings": ["bank-1"]]
        )), onApply: { request in
            pendingStore.commit(["savings": ["bank-1"]], notificationID: request.notificationID)
        })
        let workflow = makeWorkflow(
            runner: runner,
            applier: applier,
            badgeUpdates: { badgeCalls.append($0) },
            pendingStore: pendingStore
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

    @Test func disablingAlertsDuringSuspendedBankApplySuppressesLateCommitWithoutPosting() async throws {
        let pendingStore = BankWorkflowPendingStore()
        let applier = SuspendedCommitApplier(pendingStore: pendingStore)
        var isEligible = true
        var posted = 0
        let workflow = makeWorkflow(
            applier: applier,
            pendingStore: pendingStore,
            notificationPoster: { _, _, _ in posted += 1 }
        )
        let task = Task {
            await workflow.performRefresh(
                timeLimit: .seconds(25),
                isDemoMode: false,
                settings: makeSettings(alerts: true, backgroundBankSync: true),
                selectedBudget: nil,
                budgets: [],
                hasSyncCredentials: true,
                store: makeStore(),
                liveEligibility: {
                    .init(
                        sessionIsCurrent: true,
                        alertsEnabled: isEligible,
                        bankSyncEnabled: true
                    )
                }
            )
        }
        _ = try await applier.delay.waitUntilSleeping()
        isEligible = false
        applier.delay.resume()

        let output = await task.value
        let delivery = try await pendingStore.pendingNewTransactionDelivery(budgetID: "group-1")

        #expect(output.outcome == .success)
        #expect(posted == 0)
        #expect(pendingStore.suppressionCount == 1)
        #expect(delivery == nil)
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
        let applier = SleepingApplier()
        let timer = ManualTestDelay()
        let workflow = makeWorkflow(
            applier: applier,
            timer: timer
        )
        let settings = makeSettings(alerts: true, backgroundBankSync: true)

        let task = Task {
            await workflow.performRefresh(
                timeLimit: .seconds(25),
                isDemoMode: false,
                settings: settings,
                selectedBudget: nil,
                budgets: [],
                hasSyncCredentials: true,
                store: makeStore()
            )
        }
        _ = try await applier.delay.waitUntilSleeping()
        let remaining = try await timer.waitUntilSleeping()
        #expect(remaining > .seconds(22) && remaining <= .seconds(23))
        timer.resume()
        let output = await task.value

        #expect(output.outcome == .success)
        let run = try #require(output.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == true)
        #expect(run.message.contains("bank sync timed out"))
    }

    @Test func timeoutRecoversPreviouslyCommittedDurableCandidates() async throws {
        let applier = SleepingApplier()
        let timer = ManualTestDelay()
        let pendingStore = BankWorkflowPendingStore(seed: ["savings": ["committed-before-timeout"]])
        var posted = 0
        let workflow = makeWorkflow(
            applier: applier,
            timer: timer,
            pendingStore: pendingStore,
            notificationPoster: { _, _, _ in posted += 1 }
        )
        let task = Task {
            await workflow.performRefresh(
                timeLimit: .seconds(25), isDemoMode: false,
                settings: makeSettings(alerts: true, backgroundBankSync: true),
                selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeStore()
            )
        }
        _ = try await applier.delay.waitUntilSleeping()
        _ = try await timer.waitUntilSleeping()
        timer.resume()
        let output = await task.value

        #expect(output.outcome == .success)
        #expect(output.settings.pendingNewTransactionIDsByAccount["group-1|savings"] == ["committed-before-timeout"])
        #expect(posted == 1)
    }

    @Test func laterAccountFailureRecoversEarlierDurableCandidates() async {
        let pendingStore = BankWorkflowPendingStore(seed: ["checking": ["earlier-commit"]])
        let applier = FakeApplier(result: .failure(FakeWorkflowError.failed))
        var posted = 0
        let workflow = makeWorkflow(
            applier: applier,
            pendingStore: pendingStore,
            notificationPoster: { _, _, _ in posted += 1 }
        )

        let output = await workflow.performRefresh(
            timeLimit: .seconds(25), isDemoMode: false,
            settings: makeSettings(alerts: true, backgroundBankSync: true),
            selectedBudget: nil, budgets: [], hasSyncCredentials: true, store: makeStore()
        )

        #expect(output.outcome == .success)
        #expect(output.settings.pendingNewTransactionIDsByAccount["group-1|checking"] == ["earlier-commit"])
        #expect(posted == 1)
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
private final class BankWorkflowPendingStore: BackgroundPendingTransactionPersisting {
    private var byAccount: [String: [String]] = [:]
    private var delivery: LocalFirstActualStore.PendingNewTransactionDelivery?
    private(set) var suppressionCount = 0

    init(seed: [String: [String]] = [:]) {
        byAccount = seed
        let ids = seed.values.flatMap { $0 }.sorted()
        if !ids.isEmpty {
            delivery = .init(requestIdentifier: "actualist.new-transactions.persisted", transactionIDs: ids)
        }
    }

    func commit(_ inserted: [String: [String]], notificationID: String?) {
        for (accountID, ids) in inserted {
            byAccount[accountID, default: []].append(contentsOf: ids)
            byAccount[accountID] = Array(Set(byAccount[accountID] ?? [])).sorted()
        }
        let ids = byAccount.values.flatMap { $0 }.sorted()
        if let notificationID, !ids.isEmpty {
            delivery = .init(
                requestIdentifier: "actualist.new-transactions.\(notificationID)",
                transactionIDs: ids
            )
        }
    }

    func reconcilePendingNewTransactionProjection(
        budgetID: String,
        legacyStorage: [String: [String]]
    ) async throws -> [String: [String]] {
        var result = legacyStorage.filter { !$0.key.hasPrefix("\(budgetID)|") }
        for (accountID, ids) in byAccount { result["\(budgetID)|\(accountID)"] = ids }
        return result
    }

    func registerRemotePendingNewTransactions(
        _ pending: [BackgroundPendingTransactions],
        budgetID: String,
        notificationID: String
    ) async throws {
        for item in pending {
            byAccount[item.accountID, default: []].append(contentsOf: item.transactionIDs)
            byAccount[item.accountID] = Array(Set(byAccount[item.accountID] ?? [])).sorted()
        }
        let ids = byAccount.values.flatMap { $0 }.sorted()
        if !ids.isEmpty {
            delivery = .init(requestIdentifier: "actualist.new-transactions.\(notificationID)", transactionIDs: ids)
        }
    }

    func pendingNewTransactionDelivery(
        budgetID: String
    ) async throws -> LocalFirstActualStore.PendingNewTransactionDelivery? { delivery }

    func acknowledgePendingNewTransactionDelivery(
        _ delivery: LocalFirstActualStore.PendingNewTransactionDelivery,
        budgetID: String
    ) async throws { self.delivery = nil }

    func suppressPendingNewTransactionDeliveries(budgetID: String) async throws {
        suppressionCount += 1
        delivery = nil
    }
}

private enum FakeWorkflowError: Error { case failed }

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
