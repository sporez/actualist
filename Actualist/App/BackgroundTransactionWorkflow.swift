import Foundation

/// Seam for the Phase 6 background bank-sync step so workflow tests can
/// fake the SimpleFIN apply without a budget database. The production
/// conformer is `LocalFirstActualStore`.
@MainActor
protocol BackgroundBankSyncApplying {
    func backgroundBankSyncApply(request: BankSyncBackgroundApplyRequest) async throws -> BankSyncBackgroundApplyResult
}

@MainActor
protocol BackgroundPendingTransactionPersisting {
    func reconcilePendingNewTransactionProjection(
        budgetID: String,
        legacyStorage: [String: [String]]
    ) async throws -> [String: [String]]
    func registerRemotePendingNewTransactions(
        _ pending: [BackgroundPendingTransactions],
        budgetID: String,
        notificationID: String
    ) async throws
    func pendingNewTransactionDelivery(budgetID: String) async throws
        -> LocalFirstActualStore.PendingNewTransactionDelivery?
    func acknowledgePendingNewTransactionDelivery(
        _ delivery: LocalFirstActualStore.PendingNewTransactionDelivery,
        budgetID: String
    ) async throws
    func suppressPendingNewTransactionDeliveries(budgetID: String) async throws
}

/// Focused owner of the background-transaction refresh lifecycle, extracted
/// from `AppState` so AppState stays centered on connection/session/routing.
///
/// Composes `BackgroundTransactionRefreshRunner`,
/// `BackgroundRefreshDebugRecorder`, and `NewTransactionNotificationCoordinator`
/// plus the injected notification-authorization and application-badge closures.
///
/// `AppState.settings` remains the observable read model. SQLite owns pending
/// transaction state; asynchronous work returns narrow projections and run
/// diagnostics that AppState merges only while its session identity is current.
/// The recorder persists its own fields during a wake without replacing
/// unrelated settings.
///
/// Methods that would need to touch AppState-owned observable state (such as
/// `lastErrorMessage` or routing) return a focused outcome enum instead, and
/// the AppState composer applies it. The BGTask scheduler
/// (`BackgroundTransactionRefreshCoordinator`) stays separate and is
/// coordinated by AppState, not by this workflow.
@MainActor
final class BackgroundTransactionWorkflow {
    struct SessionIdentity: Equatable {
        let recoveryIdentity: Int
        let serverURL: String
        let budgetID: String?
        let localFileID: String?
        let localGroupID: String?
        let alertsEnabled: Bool
        let bankSyncEnabled: Bool
    }

    struct LiveEligibility: Sendable {
        let sessionIsCurrent: Bool
        let alertsEnabled: Bool
        let bankSyncEnabled: Bool

        static let enabled = LiveEligibility(
            sessionIsCurrent: true,
            alertsEnabled: true,
            bankSyncEnabled: true
        )
    }

    struct PendingReviewOutcome: Sendable {
        let budgetID: String
        let projection: [String: [String]]
        let clearedCount: Int
        let scope: BackgroundPendingIDClearEvent.Scope
        let pendingProjectionGeneration: Int
    }
    struct PreparedProjection: Sendable {
        let budgetID: String?
        let projection: [String: [String]]
        let pendingProjectionGeneration: Int
    }
    struct RefreshResult {
        let outcome: RefreshOutcome
        let settings: AppSettings
        let runID: UUID?
        let budgetID: String?
        let pendingProjectionGeneration: Int
    }
    private let runner: any BackgroundTransactionRefreshing
    private let debugRecorder: BackgroundRefreshDebugRecorder
    private let notifications = NewTransactionNotificationCoordinator()
    private let notificationAuthorizationRequester: @MainActor () async throws -> Bool
    private let applicationBadgeUpdater: @MainActor (Int) -> Void
    private let settingsStore: AppSettingsStore
    /// Phase 6 background bank sync step. Defaults to the store passed to
    /// `performRefresh` (which conforms); tests inject a fake.
    private let bankSyncApplier: (any BackgroundBankSyncApplying)?
    private let bankSyncTimeoutSleep: @Sendable (Duration) async throws -> Void
    /// Leaves time after network/database work to persist diagnostics, update
    /// badges, post notifications, and report BGTask completion before iOS
    /// reaches its expiration deadline.
    private let completionTimeReserve: Duration
    private let pendingTransactionStore: (any BackgroundPendingTransactionPersisting)?
    private let notificationPoster: (@MainActor (String, String, Int) async throws -> Void)?
    private var pendingProjectionGeneration = 0

    init(
        settingsStore: AppSettingsStore,
        bankSyncTimeoutSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        notificationAuthorizationRequester: @escaping @MainActor () async throws -> Bool,
        applicationBadgeUpdater: @escaping @MainActor (Int) -> Void,
        runner: (any BackgroundTransactionRefreshing)? = nil,
        bankSyncApplier: (any BackgroundBankSyncApplying)? = nil,
        completionTimeReserve: Duration = .seconds(2),
        pendingTransactionStore: (any BackgroundPendingTransactionPersisting)? = nil,
        notificationPoster: (@MainActor (String, String, Int) async throws -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        self.notificationAuthorizationRequester = notificationAuthorizationRequester
        self.applicationBadgeUpdater = applicationBadgeUpdater
        self.bankSyncApplier = bankSyncApplier
        self.bankSyncTimeoutSleep = bankSyncTimeoutSleep
        self.completionTimeReserve = completionTimeReserve
        self.pendingTransactionStore = pendingTransactionStore
        self.notificationPoster = notificationPoster
        self.debugRecorder = BackgroundRefreshDebugRecorder(settingsStore: settingsStore)
        // Constructed in the main-actor init body (not a default argument) so
        // the @MainActor struct is built in an isolated context.
        self.runner = runner ?? BackgroundTransactionRefreshRunner()
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
            return error.userFacingMessage.map(EnableOutcome.credentialPromotionFailed) ?? .disabled
        }
        return .enabled
    }

    func enableBankSync(_ isEnabled: Bool, keychain: KeychainStore) -> EnableOutcome {
        guard isEnabled else { return .disabled }
        do {
            try keychain.promoteAllItemsForBackgroundRefresh()
            return .enabled
        } catch {
            return .credentialPromotionFailed(error.localizedDescription)
        }
    }

    func suppressDeliveriesIfNeeded(
        alertsEnabled: Bool,
        budgetID: String?,
        store: LocalFirstActualStore
    ) async {
        guard !alertsEnabled, let budgetID else { return }
        try? await store.suppressPendingNewTransactionDeliveries(budgetID: budgetID)
    }

    // MARK: Preparation

    func sessionIdentity(settings: AppSettings, recoveryIdentity: Int) -> SessionIdentity {
        SessionIdentity(
            recoveryIdentity: recoveryIdentity,
            serverURL: settings.localFirstServerURLString,
            budgetID: settings.selectedBudgetID,
            localFileID: settings.selectedLocalFirstFileID,
            localGroupID: settings.selectedLocalFirstGroupID,
            alertsEnabled: settings.backgroundTransactionRefreshEnabled,
            bankSyncEnabled: settings.simplefinBackgroundSyncEnabled
        )
    }

    func liveEligibility(
        expected: SessionIdentity,
        current: SessionIdentity
    ) -> LiveEligibility {
        let sessionIsCurrent = expected.recoveryIdentity == current.recoveryIdentity
            && expected.serverURL == current.serverURL
            && expected.budgetID == current.budgetID
            && expected.localFileID == current.localFileID
            && expected.localGroupID == current.localGroupID
        return LiveEligibility(
            sessionIsCurrent: sessionIsCurrent,
            alertsEnabled: sessionIsCurrent && current.alertsEnabled,
            bankSyncEnabled: sessionIsCurrent && current.bankSyncEnabled
        )
    }

    /// Pre-foreground preparation reconciles the durable pending projection.
    /// Enabled alerts also refresh authorization; disabled alerts suppress any
    /// undelivered request. The caller merges only the returned projection after
    /// confirming the app/store session identity still matches.
    func prepare(
        isEnabled: Bool,
        settings: AppSettings,
        budgetID: String?,
        store: LocalFirstActualStore
    ) async -> PreparedProjection? {
        let projectionGeneration = beginPendingProjectionOperation()
        if isEnabled { _ = try? await notificationAuthorizationRequester() }
        guard let budgetID else {
            return PreparedProjection(
                budgetID: nil,
                projection: settings.pendingNewTransactionIDsByAccount,
                pendingProjectionGeneration: projectionGeneration
            )
        }
        do {
            let projection = try await store.reconcilePendingNewTransactionProjection(
                budgetID: budgetID,
                legacyStorage: settings.pendingNewTransactionIDsByAccount
            )
            if !isEnabled {
                try await store.suppressPendingNewTransactionDeliveries(budgetID: budgetID)
            }
            return PreparedProjection(
                budgetID: budgetID,
                projection: projection,
                pendingProjectionGeneration: projectionGeneration
            )
        } catch {
            return nil
        }
    }

    func applyPreparedProjection(
        _ prepared: PreparedProjection,
        updatesBadge: Bool,
        to settings: inout AppSettings
    ) {
        guard prepared.pendingProjectionGeneration == pendingProjectionGeneration else { return }
        mergePendingProjection(prepared.projection, budgetID: prepared.budgetID, into: &settings)
        if updatesBadge { _ = updateApplicationBadge(in: settings) }
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
        store: LocalFirstActualStore,
        liveEligibility: @escaping @MainActor () -> LiveEligibility = { .enabled }
    ) async -> RefreshResult {
        let projectionGeneration = beginPendingProjectionOperation()
        let refreshBudgetID = settings.selectedBudgetID
        if isDemoMode {
            // Demo mode is local-only and never schedules background refresh.
            return RefreshResult(outcome: .skipped, settings: settings, runID: nil,
                budgetID: refreshBudgetID, pendingProjectionGeneration: projectionGeneration)
        }

        // Mutate a local copy so debug-run/pending/badge state can be persisted
        // mid-flow (a wake is recorded before the sync so it survives a crash)
        // without passing an actor-isolated property inout across an await. The
        // composer writes the final value back to the authoritative settings.
        var local = settings

        let debugRunID = debugRecorder.beginRun(in: &local)
        var details = BackgroundRefreshDiagnosticDetails(alertsEnabled: local.backgroundTransactionRefreshEnabled)
        debugRecorder.updateDetails(details, for: debugRunID, in: &local)
        var syncStartedAt: Date?
        let notificationID = UUID().uuidString.lowercased()
        let clock = ContinuousClock()
        let totalDeadline = clock.now.advanced(by: max(.zero, timeLimit))
        let workDeadline = totalDeadline.advanced(by: .zero - completionTimeReserve)

        guard !Task.isCancelled else {
            details.refreshOutcome = .cancelled
            debugRecorder.updateDetails(details, for: debugRunID, in: &local)
            debugRecorder.completeRun(
                debugRunID,
                succeeded: false,
                message: "Cancelled before sync",
                in: &local
            )
            return RefreshResult(outcome: .cancelled, settings: local, runID: debugRunID,
                budgetID: refreshBudgetID, pendingProjectionGeneration: projectionGeneration)
        }

        do {
            // Server and bank work consume one absolute deadline. Every stage
            // receives only what remains; finalization has its own reserve.
            let runnerTimeLimit = try remainingDuration(until: workDeadline, clock: clock)
            syncStartedAt = Date()
            let outcome = try await runner.run(
                settings: local,
                selectedBudget: selectedBudget,
                budgets: budgets,
                hasSyncCredentials: hasSyncCredentials,
                store: store,
                timeLimit: runnerTimeLimit
            )
            if let syncStartedAt {
                details.serverSyncDurationMilliseconds = Self.elapsedMilliseconds(since: syncStartedAt)
            }
            try Task.checkCancellation()

            if case .synced(let result) = outcome {
                // Phase 6: after a successful pull, optionally run the
                // time-boxed server SimpleFIN download + auto-apply. A
                // failure or timeout appends to the run message and never
                // fails the parent refresh. Inserted transactions join the
                // sync's pending set so the existing notification pipeline
                // sees one combined pass.
                details.serverInsertedCount = result.newTransactionCount
                debugRecorder.updateDetails(details, for: debugRunID, in: &local)
                var runMessage = outcome.message
                let pendingStore = pendingTransactionStore ?? store
                let alertsRequested = local.backgroundTransactionRefreshEnabled
                if alertsRequested && liveEligibility().alertsEnabled {
                    _ = try remainingDuration(until: workDeadline, clock: clock)
                    try await pendingStore.registerRemotePendingNewTransactions(
                        result.pendingTransactions,
                        budgetID: result.budgetID,
                        notificationID: notificationID
                    )
                }
                if local.simplefinBackgroundSyncEnabled && liveEligibility().bankSyncEnabled {
                    details.bankOutcome = .running
                    debugRecorder.updateDetails(details, for: debugRunID, in: &local)
                    let bankStep = await runBackgroundBankSync(
                        budgetID: result.budgetID,
                        notificationID: alertsRequested && liveEligibility().alertsEnabled ? notificationID : nil,
                        remainingTime: try remainingDuration(until: workDeadline, clock: clock),
                        store: store
                    )
                    details.bankOutcome = bankStep.outcome
                    details.bankAccountCount = bankStep.accountCount
                    details.bankInsertedCount = bankStep.insertedCount
                    details.bankDurationMilliseconds = bankStep.durationMilliseconds
                    debugRecorder.updateDetails(details, for: debugRunID, in: &local)
                    if bankStep.outcome == .cancelled {
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                    runMessage += bankStep.messageSuffix
                } else {
                    details.bankOutcome = .skipped
                }

                // Notifications are consented only by the alerts toggle.
                // Bank-sync-only mode applies silently: no pending-ID
                // record, no badge, no notification.
                if alertsRequested && !liveEligibility().alertsEnabled {
                    // A bank apply may have committed after alerts were turned
                    // off. Suppress those durable rows before any delivery
                    // lookup; a session switch can make this best effort fail,
                    // but eligibility still prevents posting into that session.
                    try? await pendingStore.suppressPendingNewTransactionDeliveries(
                        budgetID: result.budgetID
                    )
                } else if alertsRequested {
                    _ = try remainingDuration(until: totalDeadline, clock: clock)
                    local.pendingNewTransactionIDsByAccount = try await pendingStore
                        .reconcilePendingNewTransactionProjection(
                            budgetID: result.budgetID,
                            legacyStorage: local.pendingNewTransactionIDsByAccount
                        )
                    details.durablePendingIDCount = notifications.pendingIDs(
                        in: local.pendingNewTransactionIDsByAccount,
                        budgetID: result.budgetID
                    ).count
                    debugRecorder.updateDetails(details, for: debugRunID, in: &local)
                    if !liveEligibility().alertsEnabled {
                        try? await pendingStore.suppressPendingNewTransactionDeliveries(
                            budgetID: result.budgetID
                        )
                    } else {
                        persistPendingProjection(
                            local.pendingNewTransactionIDsByAccount,
                            budgetID: result.budgetID
                        )
                        _ = try remainingDuration(until: totalDeadline, clock: clock)
                        let delivery = try await pendingStore.pendingNewTransactionDelivery(
                            budgetID: result.budgetID
                        )
                        if !liveEligibility().alertsEnabled {
                            try? await pendingStore.suppressPendingNewTransactionDeliveries(
                                budgetID: result.budgetID
                            )
                        } else if let delivery {
                            details.notificationCandidateCount = delivery.transactionIDs.count
                            _ = try remainingDuration(until: totalDeadline, clock: clock)
                            let badgeCount = updateApplicationBadge(in: local)
                            details.notificationOutcome = .attempted
                            debugRecorder.updateDetails(details, for: debugRunID, in: &local)
                            do {
                                try Task.checkCancellation()
                                if let notificationPoster {
                                    try await notificationPoster(
                                        result.budgetID,
                                        delivery.requestIdentifier,
                                        badgeCount
                                    )
                                } else {
                                    try await notifications.post(
                                        budgetID: result.budgetID,
                                        requestIdentifier: delivery.requestIdentifier,
                                        badgeCount: badgeCount
                                    )
                                }
                                // Once submission begins, a concurrent disable
                                // cannot retract it. Always acknowledge an
                                // accepted request so it is not posted again.
                                try await pendingStore.acknowledgePendingNewTransactionDelivery(
                                    delivery,
                                    budgetID: result.budgetID
                                )
                                details.notificationOutcome = .accepted
                            } catch where error.isCancellation {
                                details.notificationOutcome = .cancelled
                                debugRecorder.updateDetails(details, for: debugRunID, in: &local)
                                throw CancellationError()
                            } catch {
                                // Delivery and acknowledgement are best effort. An
                                // unacknowledged durable row is retried next wake.
                                details.notificationOutcome = .failed
                                debugRecorder.updateDetails(details, for: debugRunID, in: &local)
                            }
                        }
                    }
                }

                details.refreshOutcome = .succeeded
                debugRecorder.updateDetails(details, for: debugRunID, in: &local)
                debugRecorder.completeRun(
                    debugRunID,
                    succeeded: true,
                    message: runMessage,
                    in: &local
                )
                return RefreshResult(outcome: .success, settings: local, runID: debugRunID,
                    budgetID: refreshBudgetID, pendingProjectionGeneration: projectionGeneration)
            }

            details.refreshOutcome = .skipped
            debugRecorder.updateDetails(details, for: debugRunID, in: &local)
            debugRecorder.completeRun(
                debugRunID,
                succeeded: true,
                message: outcome.message,
                in: &local
            )
            return RefreshResult(outcome: .success, settings: local, runID: debugRunID,
                budgetID: refreshBudgetID, pendingProjectionGeneration: projectionGeneration)
        } catch where error.isCancellation {
            details.refreshOutcome = .cancelled
            if let syncStartedAt, details.serverSyncDurationMilliseconds == nil {
                details.serverSyncDurationMilliseconds = Self.elapsedMilliseconds(since: syncStartedAt)
            }
            if details.notificationOutcome == .attempted {
                details.notificationOutcome = .cancelled
            }
            debugRecorder.updateDetails(details, for: debugRunID, in: &local)
            debugRecorder.completeRun(
                debugRunID,
                succeeded: false,
                message: "Cancelled",
                in: &local
            )
            return RefreshResult(outcome: .cancelled, settings: local, runID: debugRunID,
                budgetID: refreshBudgetID, pendingProjectionGeneration: projectionGeneration)
        } catch BackgroundTransactionRefreshRunnerError.timeLimitExceeded {
            details.refreshOutcome = .timedOut
            if let syncStartedAt, details.serverSyncDurationMilliseconds == nil {
                details.serverSyncDurationMilliseconds = Self.elapsedMilliseconds(since: syncStartedAt)
            }
            debugRecorder.updateDetails(details, for: debugRunID, in: &local)
            debugRecorder.completeRun(
                debugRunID,
                succeeded: false,
                message: "Timed out",
                in: &local
            )
            return RefreshResult(outcome: .timedOut, settings: local, runID: debugRunID,
                budgetID: refreshBudgetID, pendingProjectionGeneration: projectionGeneration)
        } catch {
            details.refreshOutcome = .failed
            if let syncStartedAt, details.serverSyncDurationMilliseconds == nil {
                details.serverSyncDurationMilliseconds = Self.elapsedMilliseconds(since: syncStartedAt)
            }
            debugRecorder.updateDetails(details, for: debugRunID, in: &local)
            debugRecorder.completeRun(
                debugRunID,
                succeeded: false,
                message: SafeSyncDiagnostic.description(for: error),
                in: &local
            )
            return RefreshResult(outcome: .failed(SafeSyncDiagnostic.description(for: error)),
                settings: local, runID: debugRunID, budgetID: refreshBudgetID,
                pendingProjectionGeneration: projectionGeneration)
        }
    }

    // MARK: Background bank sync (Phase 6)

    private func runBackgroundBankSync(
        budgetID: String,
        notificationID: String?,
        remainingTime: Duration,
        store: LocalFirstActualStore
    ) async -> (messageSuffix: String, outcome: BackgroundRefreshDiagnosticDetails.BankOutcome, accountCount: Int?,
                insertedCount: Int?, durationMilliseconds: Int) {
        let applier = bankSyncApplier ?? store
        let startedAt = Date()
        do {
            let result = try await withTimeLimit(
                remainingTime,
                timeoutError: BackgroundBankSyncStepError.timedOut,
                sleep: bankSyncTimeoutSleep
            ) {
                try await applier.backgroundBankSyncApply(request: .init(
                    budgetID: budgetID,
                    notificationID: notificationID
                ))
            }
            let insertedCount = result.insertedTransactionIDsByAccount
                .values
                .reduce(0) { $0 + $1.count }
            let suffix = "; bank sync: \(result.accountCount) account\(result.accountCount == 1 ? "" : "s")"
                + (insertedCount > 0 ? ", \(insertedCount) added" : "")
                + " in \(Self.elapsedText(since: startedAt))"
            return (suffix, .succeeded, result.accountCount, insertedCount,
                    Self.elapsedMilliseconds(since: startedAt))
        } catch where error.isCancellation {
            // BGTask expiration must cancel the parent workflow rather than be
            // downgraded to an optional bank-step failure.
            return ("", .cancelled, nil, nil, Self.elapsedMilliseconds(since: startedAt))
        } catch BackgroundBankSyncStepError.timedOut {
            return ("; bank sync timed out after \(Self.elapsedText(since: startedAt))", .timedOut,
                    nil, nil, Self.elapsedMilliseconds(since: startedAt))
        } catch {
            return ("; bank sync failed after \(Self.elapsedText(since: startedAt))", .failed,
                    nil, nil, Self.elapsedMilliseconds(since: startedAt))
        }
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private func remainingDuration(
        until deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws -> Duration {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            throw BackgroundTransactionRefreshRunnerError.timeLimitExceeded
        }
        return remaining
    }

    private static func elapsedText(since start: Date) -> String {
        String(format: "%.1fs", max(0, Date().timeIntervalSince(start)))
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
        accountID: String?,
        transactionIDs: Set<String>,
        settings: AppSettings,
        store: LocalFirstActualStore
    ) async -> PendingReviewOutcome? {
        let projectionGeneration = beginPendingProjectionOperation()
        guard let result = try? await store.reviewPendingNewTransactions(
            budgetID: budgetID, accountID: accountID,
            transactionIDs: transactionIDs,
            projection: settings.pendingNewTransactionIDsByAccount
        ) else { return nil }
        return PendingReviewOutcome(
            budgetID: budgetID,
            projection: result.projection,
            clearedCount: result.clearedCount,
            scope: accountID == nil ? .budget : .account,
            pendingProjectionGeneration: projectionGeneration
        )
    }

    func applyPendingReviewOutcome(_ outcome: PendingReviewOutcome, to settings: inout AppSettings) {
        guard outcome.pendingProjectionGeneration == pendingProjectionGeneration else { return }
        mergePendingProjection(outcome.projection, budgetID: outcome.budgetID, into: &settings)
        if outcome.clearedCount > 0 {
            debugRecorder.recordPendingIDClear(
                scope: outcome.scope,
                count: outcome.clearedCount,
                in: &settings
            )
        }
        persistPendingProjection(
            settings.pendingNewTransactionIDsByAccount,
            budgetID: outcome.budgetID
        )
        _ = updateApplicationBadge(in: settings)
    }

    func applyRefreshResult(_ result: RefreshResult, to settings: inout AppSettings) {
        if let runID = result.runID,
           let run = result.settings.backgroundRefreshDebug.recentRuns.first(where: { $0.id == runID }) {
            if let index = settings.backgroundRefreshDebug.recentRuns.firstIndex(where: { $0.id == runID }) {
                settings.backgroundRefreshDebug.recentRuns[index] = run
            } else {
                settings.backgroundRefreshDebug.totalWakeCount += 1
                settings.backgroundRefreshDebug.recentRuns.insert(run, at: 0)
                settings.backgroundRefreshDebug.recentRuns = Array(
                    settings.backgroundRefreshDebug.recentRuns.prefix(20)
                )
            }
        }
        if result.pendingProjectionGeneration == pendingProjectionGeneration,
           let budgetID = result.budgetID {
            mergePendingProjection(
                result.settings.pendingNewTransactionIDsByAccount,
                budgetID: budgetID,
                into: &settings
            )
        }
        settingsStore.save(settings)
    }

    private func beginPendingProjectionOperation() -> Int {
        pendingProjectionGeneration &+= 1
        return pendingProjectionGeneration
    }

    private func persistPendingProjection(
        _ projection: [String: [String]],
        budgetID: String? = nil
    ) {
        var persisted = settingsStore.load()
        if let budgetID {
            let prefix = "\(budgetID)|"
            persisted.pendingNewTransactionIDsByAccount = persisted.pendingNewTransactionIDsByAccount
                .filter { !$0.key.hasPrefix(prefix) }
            for entry in projection where entry.key.hasPrefix(prefix) {
                persisted.pendingNewTransactionIDsByAccount[entry.key] = entry.value
            }
        } else {
            persisted.pendingNewTransactionIDsByAccount = projection
        }
        settingsStore.save(persisted)
    }

    private func mergePendingProjection(
        _ projection: [String: [String]],
        budgetID: String?,
        into settings: inout AppSettings
    ) {
        guard let budgetID else {
            settings.pendingNewTransactionIDsByAccount = projection
            return
        }
        let prefix = "\(budgetID)|"
        settings.pendingNewTransactionIDsByAccount = settings.pendingNewTransactionIDsByAccount
            .filter { !$0.key.hasPrefix(prefix) }
        for entry in projection where entry.key.hasPrefix(prefix) {
            settings.pendingNewTransactionIDsByAccount[entry.key] = entry.value
        }
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

}
