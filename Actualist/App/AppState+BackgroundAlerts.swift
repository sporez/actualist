import Foundation

extension AppState {
    func updateBackgroundTransactionRefreshEnabled(_ isEnabled: Bool) async {
        let outcome = await backgroundTransactionWorkflow.enable(isEnabled, keychain: keychain)
        settings.backgroundTransactionRefreshEnabled = (outcome == .enabled)
        await backgroundTransactionWorkflow.suppressDeliveriesIfNeeded(alertsEnabled:
            settings.backgroundTransactionRefreshEnabled, budgetID: settings.selectedBudgetID, store: localFirstStore)
        settingsStore.save(settings)
        switch outcome {
        case .enabled:
            BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: self)
        case .disabled, .authorizationDenied:
            BackgroundTransactionRefreshCoordinator.shared.cancelOrReschedule(for: self)
        case .credentialPromotionFailed(let message):
            lastErrorMessage = message
            BackgroundTransactionRefreshCoordinator.shared.cancelOrReschedule(for: self)
        }
    }

    /// Enabling background bank sync promotes Keychain items for background
    /// access (like the alerts toggle) but never requests notification
    /// authorization — it posts nothing.
    func updateSimpleFINBackgroundSyncEnabled(_ isEnabled: Bool) async {
        let outcome = backgroundTransactionWorkflow.enableBankSync(isEnabled, keychain: keychain)
        if case .credentialPromotionFailed(let message) = outcome {
            lastErrorMessage = message
        }
        settings.simplefinBackgroundSyncEnabled = (outcome == .enabled)
        settingsStore.save(settings)
        if outcome == .enabled {
            BackgroundTransactionRefreshCoordinator.shared.scheduleIfNeeded(for: self)
        } else {
            BackgroundTransactionRefreshCoordinator.shared.cancelOrReschedule(for: self)
        }
    }

    func prepareBackgroundTransactionNotifications() async {
        let identity = backgroundSessionIdentity
        if let prepared = await backgroundTransactionWorkflow.prepare(isEnabled:
            settings.backgroundTransactionRefreshEnabled, settings: settings,
            budgetID: settings.selectedBudgetID, store: localFirstStore),
           identity == backgroundSessionIdentity {
            backgroundTransactionWorkflow.applyPreparedProjection(prepared, updatesBadge: settings.backgroundTransactionRefreshEnabled, to: &settings)
        }
        settingsStore.save(settings)
    }

    func performBackgroundTransactionRefresh(timeLimit: Duration = .seconds(25)) async -> Bool {
        let identity = backgroundSessionIdentity
        let result = await backgroundTransactionWorkflow.performRefresh(
            timeLimit: timeLimit,
            isDemoMode: isDemoMode,
            settings: settings,
            selectedBudget: selectedBudget,
            budgets: budgets,
            hasSyncCredentials: hasSyncCredentials,
            store: localFirstStore,
            liveEligibility: { [weak self] in
                guard let self else {
                    return .init(sessionIsCurrent: false, alertsEnabled: false, bankSyncEnabled: false)
                }
                return self.backgroundTransactionWorkflow.liveEligibility(
                    expected: identity,
                    current: self.backgroundSessionIdentity
                )
            }
        )
        if identity == backgroundSessionIdentity {
            backgroundTransactionWorkflow.applyRefreshResult(result, to: &settings)
        } else { return false }
        switch result.outcome {
        case .success:
            return true
        case .skipped, .cancelled, .timedOut:
            return false
        case .failed(let message):
            lastErrorMessage = message
            return false
        }
    }

    /// Scheduling runs on every appear and background transition. Repeating
    /// the previous attempt's outcome and schedule would rewrite the whole
    /// settings blob twice (memory and persisted copy) for no new information.
    static let unchangedScheduleTolerance: TimeInterval = 10 * 60

    static func isRedundantScheduleAttempt(
        previous: BackgroundRefreshScheduleAttempt?,
        succeeded: Bool,
        earliestBeginDate: Date?,
        message: String
    ) -> Bool {
        guard let previous, previous.succeeded == succeeded, previous.message == message else { return false }
        switch (previous.earliestBeginDate, earliestBeginDate) {
        case (nil, nil): return true
        case let (old?, new?): return abs(new.timeIntervalSince(old)) < unchangedScheduleTolerance
        default: return false
        }
    }

    func recordBackgroundRefreshScheduleAttempt(succeeded: Bool,
        earliestBeginDate: Date?,
        message: String
    ) {
        guard !Self.isRedundantScheduleAttempt(
            previous: settings.backgroundRefreshDebug.recentScheduleAttempts.first,
            succeeded: succeeded, earliestBeginDate: earliestBeginDate, message: message
        ) else { return }
        backgroundTransactionWorkflow.recordScheduleAttempt(succeeded: succeeded,
            earliestBeginDate: earliestBeginDate, message: message, in: &settings)
    }

    func pendingNewTransactionIDs(budgetID: String, accountID: String) -> Set<String> {
        backgroundTransactionWorkflow.pendingNewTransactionIDs(budgetID: budgetID,
            accountID: accountID, in: settings)
    }

    func pendingNewTransactionIDs(budgetID: String) -> Set<String> {
        backgroundTransactionWorkflow.pendingNewTransactionIDs(budgetID: budgetID, in: settings)
    }

    func clearPendingNewTransactionIDs(_ intent: PendingNewTransactionReviewIntent) async {
        guard settings.selectedBudgetID == intent.budgetID else { return }
        let identity = backgroundSessionIdentity
        if let outcome = await backgroundTransactionWorkflow.clearPendingNewTransactionIDs(budgetID:
            intent.budgetID, accountID: intent.accountID, transactionIDs: intent.transactionIDs,
            settings: settings, store: localFirstStore),
           identity == backgroundSessionIdentity {
            backgroundTransactionWorkflow.applyPendingReviewOutcome(outcome, to: &settings)
        }
    }

    @discardableResult
    func updateApplicationBadge() -> Int {
        backgroundTransactionWorkflow.updateApplicationBadge(in: settings)
    }

    func routeToSpendingFromNotification(budgetID: String) async {
        guard settings.selectedBudgetID == budgetID else { return }
        // A notification tap can arrive while the Settings cover is presented
        // (for example, the developer test notification is posted from there).
        // Dismiss it first so the Spending route is actually visible, the same
        // way widget deep links defer navigation through `afterDismissingSettings`.
        routeCoordinator.afterDismissingSettings { [weak self] in
            guard let self else { return }
            self.accountNavigationPath = []
            self.selectedTab = .spending
            self.routeCoordinator.enqueue(.tab(.spending))
        }
    }

    #if DEBUG
    func postDebugNewTransactionNotification() async throws {
        guard let budgetID = settings.selectedBudgetID else {
            throw DebugNotificationError.missingBudget
        }
        try await backgroundTransactionWorkflow.postDebugNotification(
            budgetID: budgetID,
            repository: accountRepository
        )
    }
    #endif
}
