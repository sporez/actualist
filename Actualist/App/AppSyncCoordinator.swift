import Foundation

enum AppSyncFailureReason: Equatable, Sendable {
    /// Transport, decoding, or other error with no more specific classification.
    case general
    /// The session is no longer valid; the user must sign in again.
    case authenticationRequired
    /// The server was reachable but refused this budget's sync (for example its
    /// encryption changed on the server). The connection itself is healthy.
    case budgetSyncRejected
    /// A Keychain read needed for this operation failed without invalidating the local budget.
    case credentialUnavailable(KeychainReadError)
}

enum AppSyncOperationOutcome: Equatable, Sendable {
    case succeeded
    case alreadyRequested
    case cancelledOrStale
    case failed(message: String, reason: AppSyncFailureReason)
}

extension AppSyncFailureReason {
    /// The connection status a failed refresh should publish. A budget-scoped
    /// rejection means the server answered, so it must not read as offline.
    var connectionStatus: ServerConnectionStatus {
        switch self {
        case .budgetSyncRejected: .syncBlocked
        case .authenticationRequired, .general, .credentialUnavailable: .offline
        }
    }
}

struct AppSyncRefreshResult: Equatable, Sendable {
    let outcome: AppSyncOperationOutcome
    let shouldPublish: Bool
}

@MainActor
final class AppSyncCoordinator {
    struct RefreshRequest: Equatable, Sendable {
        let budgetID: String
        fileprivate let id: UUID
        fileprivate let sessionID: UUID?
    }

    private struct ActiveRefresh {
        let request: RefreshRequest
        let task: Task<AppSyncOperationOutcome, Never>
    }

    private var foregroundSessionID: UUID?
    private var automaticRefreshRequested = false
    private var activeRefresh: ActiveRefresh?

    func beginForegroundSession() -> Bool {
        guard foregroundSessionID == nil else {
            return false
        }
        foregroundSessionID = UUID()
        automaticRefreshRequested = false
        return true
    }

    func endForegroundSession() {
        foregroundSessionID = nil
        automaticRefreshRequested = false
        cancelRefresh()
    }

    func cancelRefresh() {
        let task = activeRefresh?.task
        activeRefresh = nil
        task?.cancel()
    }

    func isCurrent(_ request: RefreshRequest) -> Bool {
        guard activeRefresh?.request == request else {
            return false
        }
        guard let requestSessionID = request.sessionID else {
            return true
        }
        return foregroundSessionID == requestSessionID
    }

    func refresh(
        budgetID: String,
        serverURLString: String,
        force: Bool,
        store: LocalFirstActualStore,
        onStart: @escaping @MainActor @Sendable () -> Void,
        isBudgetCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> AppSyncRefreshResult {
        await refresh(
            budgetID: budgetID,
            force: force,
            onStart: onStart
        ) { [weak self] request in
            guard let self else {
                return .cancelledOrStale
            }
            do {
                try await store.refresh(
                    budgetID: budgetID,
                    serverURLString: serverURLString
                )
                guard self.isCurrent(request), isBudgetCurrent() else {
                    return .cancelledOrStale
                }
                return .succeeded
            } catch where error.isCancellation {
                return .cancelledOrStale
            } catch {
                guard isBudgetCurrent() else {
                    return .cancelledOrStale
                }
                return .failed(
                    message: error.localizedDescription,
                    reason: Self.failureReason(for: error)
                )
            }
        }
    }

    /// Classifies a sync/refresh error for the UI's connection status. Typed
    /// domain conditions are the only errors that get a non-`.general` reason;
    /// every other failure keeps the existing offline presentation.
    private static func failureReason(for error: Error) -> AppSyncFailureReason {
        if let error = error as? KeychainReadError { return .credentialUnavailable(error) }
        if (error as? ActualAPIError)?.isAuthenticationFailure == true {
            return .authenticationRequired
        }
        if (error as? LocalFirstError) == .budgetEncryptionChanged {
            return .budgetSyncRejected
        }
        return .general
    }

    func refresh(
        budgetID: String,
        force: Bool,
        onStart: @escaping @MainActor @Sendable () -> Void = {},
        operation: @escaping @MainActor @Sendable (RefreshRequest) async -> AppSyncOperationOutcome
    ) async -> AppSyncRefreshResult {
        if !force {
            guard foregroundSessionID != nil else {
                return AppSyncRefreshResult(outcome: .cancelledOrStale, shouldPublish: false)
            }
            guard !automaticRefreshRequested else {
                return AppSyncRefreshResult(outcome: .alreadyRequested, shouldPublish: false)
            }
            automaticRefreshRequested = true
        }

        if let activeRefresh, activeRefresh.request.budgetID == budgetID {
            return AppSyncRefreshResult(
                outcome: await activeRefresh.task.value,
                shouldPublish: false
            )
        }

        if activeRefresh != nil {
            cancelRefresh()
        }

        let request = RefreshRequest(
            budgetID: budgetID,
            id: UUID(),
            sessionID: foregroundSessionID
        )
        onStart()
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else {
                return AppSyncOperationOutcome.cancelledOrStale
            }
            let result = await operation(request)
            guard !Task.isCancelled, self.isCurrent(request) else {
                return .cancelledOrStale
            }
            return result
        }
        activeRefresh = ActiveRefresh(request: request, task: task)

        let result = await task.value
        if activeRefresh?.request == request {
            activeRefresh = nil
        }
        return AppSyncRefreshResult(outcome: result, shouldPublish: true)
    }
}
