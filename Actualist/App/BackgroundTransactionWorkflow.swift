import Foundation

/// Focused owner of the background-transaction refresh lifecycle, extracted
/// from `AppState` so AppState stays centered on connection/session/routing.
///
/// Composes `BackgroundTransactionRefreshRunner`,
/// `BackgroundRefreshDebugRecorder`, and `NewTransactionNotificationCoordinator`
/// plus the injected notification-authorization and application-badge closures.
///
/// `AppState.settings` remains the single source of truth.
///
/// - Synchronous methods (pending-ID lookup/clear, badge, schedule-attempt
///   recording) mutate the authoritative `AppSettings` via `inout` and persist,
///   exactly as `BackgroundRefreshDebugRecorder` already does.
/// - Asynchronous methods cannot take an actor-isolated property `inout`
///   across an await. `enable` is outcome-only (AppState mutates `settings`
///   live); `prepare` reads a value snapshot; `performRefresh` mutates a local
///   copy (persisting mid-flow so a recorded wake survives a crash) and returns
///   the final `settings` for AppState to write back.
///
/// Methods that would need to touch AppState-owned observable state (such as
/// `lastErrorMessage` or routing) return a focused outcome enum instead, and
/// the AppState composer applies it. The BGTask scheduler
/// (`BackgroundTransactionRefreshCoordinator`) stays separate and is
/// coordinated by AppState, not by this workflow.
@MainActor
final class BackgroundTransactionWorkflow {
    private let runner = BackgroundTransactionRefreshRunner()
    private let debugRecorder: BackgroundRefreshDebugRecorder
    private let notifications = NewTransactionNotificationCoordinator()
    private let notificationAuthorizationRequester: @MainActor () async throws -> Bool
    private let applicationBadgeUpdater: @MainActor (Int) -> Void
    private let settingsStore: AppSettingsStore

    init(
        settingsStore: AppSettingsStore,
        notificationAuthorizationRequester: @escaping @MainActor () async throws -> Bool,
        applicationBadgeUpdater: @escaping @MainActor (Int) -> Void
    ) {
        self.settingsStore = settingsStore
        self.notificationAuthorizationRequester = notificationAuthorizationRequester
        self.applicationBadgeUpdater = applicationBadgeUpdater
        self.debugRecorder = BackgroundRefreshDebugRecorder(settingsStore: settingsStore)
    }

    // MARK: Enablement

    enum EnableOutcome: Equatable {
        /// Setting was enabled after authorization and credential promotion.
        case enabled
        /// Setting was disabled (caller requested or a precondition failed).
        case disabled
        /// Notification authorization was not granted; setting disabled.
        case authorizationDenied
        /// Keychain credential promotion failed; setting disabled.
        case credentialPromotionFailed(String)
    }

    /// Requests notification authorization and promotes keychain items to
    /// after-first-unlock accessibility before enabling. Returns an outcome
    /// only; `AppState` owns the authoritative `settings` mutation,
    /// persistence, `lastErrorMessage` surfacing, and BGTask scheduler
    /// coordination. This mirrors `AppSyncCoordinator`, whose async `refresh`
    /// returns an outcome rather than mutating actor-isolated `settings`
    /// inout across an await.
    func enable(
        _ isEnabled: Bool,
        keychain: KeychainStore
    ) async -> EnableOutcome {
        guard isEnabled else {
            return .disabled
        }

        do {
            let granted = try await notificationAuthorizationRequester()
            guard granted else {
                return .authorizationDenied
            }
            try keychain.promoteAllItemsForBackgroundRefresh()
        } catch {
            return .credentialPromotionFailed(error.localizedDescription)
        }
        return .enabled
    }

    // MARK: Preparation

    /// Pre-foreground preparation: re-request notification authorization and
    /// refresh the application badge from the persisted pending-transaction
    /// state. No-op when background refresh is disabled. Reads `settings` by
    /// value (no mutation); takes a snapshot because the authorization request
    /// is async and an actor-isolated property cannot be passed inout across an
    /// await.
    func prepare(isEnabled: Bool, settings: AppSettings) async {
        guard isEnabled else {
            return
        }
        _ = try? await notificationAuthorizationRequester()
        _ = updateApplicationBadge(in: settings)
    }

    // MARK: Refresh execution

    enum RefreshOutcome: Equatable {
        /// The run completed (synced, or the runner skipped for a known reason).
        case success
        /// Demo mode is local-only and never runs a background refresh.
        case skipped
        /// The task was cancelled before or during the sync.
        case cancelled
        /// The sync exceeded the time limit.
        case timedOut
        /// The sync threw; the message should surface as `lastErrorMessage`.
        case failed(String)
    }

    /// Runs one background transaction refresh, recording a debug run, syncing
    /// via the runner, recording pending new-transaction IDs, updating the
    /// badge, posting a notification when new transactions arrive, and
    /// recording the completion outcome. Returns a focused result so AppState
    /// can set `lastErrorMessage` for the caller.
    func performRefresh(
        timeLimit: Duration,
        isDemoMode: Bool,
        settings: AppSettings,
        selectedBudget: ActualBudget?,
        budgets: [ActualBudget],
        hasSyncCredentials: Bool,
        store: LocalFirstActualStore
    ) async -> (outcome: RefreshOutcome, settings: AppSettings) {
        if isDemoMode {
            // Demo mode is local-only and never schedules background refresh.
            return (.skipped, settings)
        }

        // Mutate a local copy so debug-run/pending/badge state can be persisted
        // mid-flow (a wake is recorded before the sync so it survives a crash)
        // without passing an actor-isolated property inout across an await. The
        // composer writes the final value back to the authoritative settings.
        var local = settings

        let debugRunID = debugRecorder.beginRun(in: &local)

        guard !Task.isCancelled else {
            debugRecorder.completeRun(
                debugRunID,
                succeeded: false,
                message: "Cancelled before sync",
                in: &local
            )
            return (.cancelled, local)
        }

        do {
            let outcome = try await runner.run(
                settings: local,
                selectedBudget: selectedBudget,
                budgets: budgets,
                hasSyncCredentials: hasSyncCredentials,
                store: store,
                timeLimit: timeLimit
            )

            if case .synced(let result) = outcome {
                for pending in result.pendingTransactions {
                    record(
                        pending.transactionIDs,
                        budgetID: result.budgetID,
                        accountID: pending.accountID,
                        in: &local
                    )
                }
                if result.newTransactionCount > 0 {
                    let badgeCount = updateApplicationBadge(in: local)
                    try await notifications.post(
                        budgetID: result.budgetID,
                        badgeCount: badgeCount
                    )
                }
            }

            debugRecorder.completeRun(
                debugRunID,
                succeeded: true,
                message: outcome.message,
                in: &local
            )
            return (.success, local)
        } catch is CancellationError {
            debugRecorder.completeRun(
                debugRunID,
                succeeded: false,
                message: "Cancelled",
                in: &local
            )
            return (.cancelled, local)
        } catch BackgroundTransactionRefreshRunnerError.timeLimitExceeded {
            debugRecorder.completeRun(
                debugRunID,
                succeeded: false,
                message: "Timed out",
                in: &local
            )
            return (.timedOut, local)
        } catch {
            debugRecorder.completeRun(
                debugRunID,
                succeeded: false,
                message: error.localizedDescription,
                in: &local
            )
            return (.failed(error.localizedDescription), local)
        }
    }

    // MARK: Scheduling diagnostics

    func recordScheduleAttempt(
        succeeded: Bool,
        earliestBeginDate: Date?,
        message: String,
        in settings: inout AppSettings
    ) {
        debugRecorder.recordScheduleAttempt(
            succeeded: succeeded,
            earliestBeginDate: earliestBeginDate,
            message: message,
            in: &settings
        )
    }

    // MARK: Pending new-transaction IDs

    func pendingNewTransactionIDs(
        budgetID: String,
        accountID: String,
        in settings: AppSettings
    ) -> Set<String> {
        notifications.pendingIDs(
            in: settings.pendingNewTransactionIDsByAccount,
            budgetID: budgetID,
            accountID: accountID
        )
    }

    func pendingNewTransactionIDs(
        budgetID: String,
        in settings: AppSettings
    ) -> Set<String> {
        notifications.pendingIDs(
            in: settings.pendingNewTransactionIDsByAccount,
            budgetID: budgetID
        )
    }

    func clearPendingNewTransactionIDs(
        budgetID: String,
        accountID: String,
        in settings: inout AppSettings
    ) {
        guard notifications.clear(
            budgetID: budgetID,
            accountID: accountID,
            in: &settings.pendingNewTransactionIDsByAccount
        ) else {
            return
        }
        settingsStore.save(settings)
        _ = updateApplicationBadge(in: settings)
    }

    func clearPendingNewTransactionIDs(
        budgetID: String,
        in settings: inout AppSettings
    ) {
        guard notifications.clear(
            budgetID: budgetID,
            in: &settings.pendingNewTransactionIDsByAccount
        ) else {
            return
        }
        settingsStore.save(settings)
        _ = updateApplicationBadge(in: settings)
    }

    @discardableResult
    func updateApplicationBadge(in settings: AppSettings) -> Int {
        let badgeCount = notifications.pendingIDCount(
            in: settings.pendingNewTransactionIDsByAccount
        )
        applicationBadgeUpdater(badgeCount)
        return badgeCount
    }

    // MARK: Debug notification (DEBUG only)

    #if DEBUG
    func postDebugNotification(
        budgetID: String,
        repository: any AccountRepositoryProtocol
    ) async throws {
        try await notifications.postDebug(
            budgetID: budgetID,
            repository: repository
        )
    }
    #endif

    private func record(
        _ transactionIDs: [String],
        budgetID: String,
        accountID: String,
        in settings: inout AppSettings
    ) {
        notifications.record(
            transactionIDs,
            budgetID: budgetID,
            accountID: accountID,
            in: &settings.pendingNewTransactionIDsByAccount
        )
        settingsStore.save(settings)
    }
}
