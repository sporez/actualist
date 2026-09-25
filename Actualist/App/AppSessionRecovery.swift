import Foundation
import Observation

/// The launch restoration operation owns its cancellation identity and access
/// state. It never keeps credential bytes; the store re-reads Keychain at use.
@MainActor
@Observable
final class AppSessionRecovery {
    enum State: Equatable {
        case idle
        case localOnly(KeychainReadError)
        case blocked(KeychainReadError)
    }

    enum CredentialAvailability: Equatable {
        case available
        case absent
        case unavailable(KeychainReadError)
    }

    enum RetryAction {
        case unavailable(String)
        case needsConnection
        case refresh
        case restore
        case discover
    }

    func retry(keychain: KeychainStore, hasOpenBudget: Bool, hasSelection: Bool) -> RetryAction {
        let availability = Self.credentialAvailability(keychain: keychain)
        invalidate()
        switch availability {
        case .unavailable(let error):
            noteFailure(error, hasOpenBudget: hasOpenBudget)
            return .unavailable(error.localizedDescription)
        case .absent:
            clear()
            return .needsConnection
        case .available:
            clear()
            if hasOpenBudget { return .refresh }
            return hasSelection ? .restore : .discover
        }
    }

    static func credentialAvailability(keychain: KeychainStore) -> CredentialAvailability {
        do {
            return try keychain.readActualSyncToken() == nil ? .absent : .available
        } catch let error as KeychainReadError {
            return .unavailable(error)
        } catch {
            return .unavailable(.unreadable)
        }
    }

    func initialSession(settings: AppSettings, keychain: KeychainStore) -> (SetupPhase, ServerConnectionStatus) {
        let availability = Self.credentialAvailability(keychain: keychain)
        if settings.selectedBudgetID != nil, settings.selectedLocalFirstFileID != nil {
            return (.restoringBudget, availability == .available ? .connecting : .offline)
        }
        if case .unavailable(let error) = availability, !settings.localFirstServerURLString.isEmpty {
            noteFailure(error, hasOpenBudget: false)
            return (.credentialUnavailable, .offline)
        }
        if settings.localFirstServerURLString.isEmpty || availability == .absent {
            return (.needsConnection, .offline)
        }
        return (.selectingBudget, .online)
    }

    func phaseAfterCancelingReauthentication(
        selectedBudgetID: String?, store: LocalFirstActualStore, keychain: KeychainStore
    ) -> SetupPhase {
        if let selectedBudgetID, store.isOpen(budgetID: selectedBudgetID) { return .ready }
        switch Self.credentialAvailability(keychain: keychain) {
        case .available: return .selectingBudget
        case .absent: return .needsConnection
        case .unavailable(let error):
            noteFailure(error, hasOpenBudget: false)
            return .credentialUnavailable
        }
    }

    var message: String? {
        switch state {
        case .idle: nil
        case .blocked(let error), .localOnly(let error): error.localizedDescription
        }
    }

    func requireDiscoveryCredentials(settings: AppSettings, keychain: KeychainStore) throws {
        guard !settings.localFirstServerURLString.isEmpty else { throw LocalFirstError.missingServerURL }
        switch Self.credentialAvailability(keychain: keychain) {
        case .available: break
        case .absent: throw LocalFirstError.missingSyncToken
        case .unavailable(let error):
            noteFailure(error, hasOpenBudget: false)
            throw error
        }
    }

    func restoredStatus(isDemoMode: Bool, keychain: KeychainStore) -> ServerConnectionStatus {
        if isDemoMode { return .offline }
        switch Self.credentialAvailability(keychain: keychain) {
        case .available: return .connecting
        case .absent: return .offline
        case .unavailable(let error):
            noteFailure(error, hasOpenBudget: true)
            return .offline
        }
    }

    func blockedError(keychain: KeychainStore) -> KeychainReadError? {
        if case .blocked(let error) = state { return error }
        if case .unavailable(let error) = Self.credentialAvailability(keychain: keychain) {
            noteFailure(error, hasOpenBudget: false)
            return error
        }
        return nil
    }

    func openedBudgetStatus(
        keychain: KeychainStore,
        credentialError: KeychainReadError? = nil
    ) -> (ServerConnectionStatus, String?) {
        if let credentialError {
            noteFailure(credentialError, hasOpenBudget: true)
            return (.offline, credentialError.localizedDescription)
        }
        switch Self.credentialAvailability(keychain: keychain) {
        case .available:
            clear()
            return (.online, nil)
        case .absent:
            return (.offline, nil)
        case .unavailable(let error):
            noteFailure(error, hasOpenBudget: true)
            return (.offline, error.localizedDescription)
        }
    }

    enum Outcome {
        case opened(ActualBudget)
        case missingCache
        case failed(Error)
        case superseded
    }

    enum LaunchOutcome {
        case opened(ActualBudget, ServerConnectionStatus)
        case discovered(BudgetDiscovery)
        case blocked(KeychainReadError)
        case needsConnection
        case failed(Error)
        case superseded
    }

    enum SelectionOutcome {
        case opened(KeychainReadError?)
        case restored(Error)
        case failed(Error)
        case superseded
    }

    enum ReimportOutcome {
        case succeeded
        case failed(Error, ServerConnectionStatus)
        case superseded
    }

    func reimport(
        _ budget: ActualBudget,
        serverURLString: String,
        encryptionPassword: String?,
        store: LocalFirstActualStore
    ) async -> ReimportOutcome {
        let identity = generation
        do {
            try await store.reimportBudget(
                budget, serverURLString: serverURLString, encryptionPassword: encryptionPassword
            )
            guard identity == generation, !Task.isCancelled else { return .superseded }
            return .succeeded
        } catch {
            guard identity == generation, !Task.isCancelled, !error.isCancellation else { return .superseded }
            let isOpen = store.isOpen(budgetID: budget.syncID)
            noteFailure(error, hasOpenBudget: isOpen)
            let status: ServerConnectionStatus = (error as? LocalFirstError) == .budgetEncryptionChanged
                ? .syncBlocked : (isOpen ? .online : .offline)
            return .failed(error, status)
        }
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var discoveryTask: Task<BudgetDiscovery, Error>?

    var identity: Int { generation }
    func isCurrent(_ identity: Int) -> Bool { identity == generation }

    func invalidate() {
        generation &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        state = .idle
    }

    func noteFailure(_ error: KeychainReadError, hasOpenBudget: Bool) {
        state = hasOpenBudget ? .localOnly(error) : .blocked(error)
    }

    func noteFailure(_ error: Error, hasOpenBudget: Bool) {
        if let accessError = error as? KeychainReadError {
            noteFailure(accessError, hasOpenBudget: hasOpenBudget)
        }
    }

    func clear() { state = .idle }

    func restore(settings: AppSettings, store: LocalFirstActualStore) async -> Outcome {
        let identity = generation
        guard settings.selectedBudgetID != nil,
              let fileID = settings.selectedLocalFirstFileID else { return .missingCache }
        let budget = ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: settings.selectedLocalFirstGroupID,
            name: settings.selectedBudgetName ?? "Selected Budget",
            state: nil
        )
        do {
            let opened = try await store.openCachedBudget(budget, expectedGeneration: store.budgetSessionGeneration)
            guard identity == generation, !Task.isCancelled else { return .superseded }
            guard opened else { return .missingCache }
            guard let selectedBudgetID = settings.selectedBudgetID,
                  store.isOpen(budgetID: selectedBudgetID) else {
                store.reset()
                return .missingCache
            }
            return .opened(budget)
        } catch {
            guard identity == generation, !Task.isCancelled else { return .superseded }
            if let keychainError = error as? KeychainReadError {
                noteFailure(keychainError, hasOpenBudget: false)
            }
            return .failed(error)
        }
    }

    func restoreForLaunch(
        settings: AppSettings,
        keychain: KeychainStore,
        store: LocalFirstActualStore,
        isDemoMode: Bool
    ) async -> LaunchOutcome {
        let identity = generation
        let status = restoredStatus(isDemoMode: isDemoMode, keychain: keychain)
        if case .opened(let budget) = await restore(settings: settings, store: store) {
            guard identity == generation, !Task.isCancelled else { return .superseded }
            return .opened(budget, status)
        }
        guard identity == generation, !Task.isCancelled else { return .superseded }
        if let error = blockedError(keychain: keychain) { return .blocked(error) }

        do {
            let discovery = try await discoverBudgets(settings: settings, store: store)
            guard identity == generation, !Task.isCancelled else { return .superseded }
            return .discovered(discovery)
        } catch {
            guard identity == generation, !Task.isCancelled, !error.isCancellation else { return .superseded }
            if case .opened(let budget) = await restore(settings: settings, store: store) {
                guard identity == generation else { return .superseded }
                return .opened(budget, .offline)
            }
            guard identity == generation else { return .superseded }
            if let blocked = blockedError(keychain: keychain) { return .blocked(blocked) }
            if case .absent = Self.credentialAvailability(keychain: keychain) { return .needsConnection }
            return .failed(error)
        }
    }

    func openSelectedBudget(
        _ budget: ActualBudget,
        serverURLString: String,
        encryptionPassword: String?,
        previousBudget: ActualBudget?,
        canRestorePreviousBudget: Bool,
        store: LocalFirstActualStore
    ) async -> SelectionOutcome {
        let identity = generation
        do {
            let credentialError = try await store.openBudget(
                budget, serverURLString: serverURLString, encryptionPassword: encryptionPassword
            )
            guard identity == generation, !Task.isCancelled else { return .superseded }
            guard store.isOpen(budgetID: budget.syncID) else { throw LocalFirstError.budgetNotOpened }
            return .opened(credentialError)
        } catch {
            guard identity == generation, !Task.isCancelled, !error.isCancellation else { return .superseded }
            if canRestorePreviousBudget, let previousBudget {
                store.closeOpenBudget()
                let restored = (try? await store.openCachedBudget(
                    previousBudget, expectedGeneration: store.budgetSessionGeneration
                )) == true
                guard identity == generation, !Task.isCancelled else { return .superseded }
                if restored { return .restored(error) }
            }
            return .failed(error)
        }
    }

    func discoveryFailure(_ error: Error, hasOpenBudget: Bool, hasSelection: Bool) -> SetupPhase? {
        if let accessError = error as? KeychainReadError {
            noteFailure(accessError, hasOpenBudget: hasOpenBudget)
            return hasOpenBudget ? nil : .credentialUnavailable
        }
        if (error as? LocalFirstError) == .missingSyncToken
            || (error as? LocalFirstError) == .missingServerURL
            || !hasSelection { return .needsConnection }
        return nil
    }

    struct BudgetDiscovery {
        let budgets: [ActualBudget]
        let selectedBudget: ActualBudget?
        let selectedIsOpen: Bool
        let credentialError: KeychainReadError?
    }

    func discoverBudgets(settings: AppSettings, store: LocalFirstActualStore) async throws -> BudgetDiscovery {
        let identity = generation
        if let discoveryTask {
            let result = try await discoveryTask.value
            try Task.checkCancellation()
            guard identity == generation else { throw CancellationError() }
            return result
        }
        let task = Task {
            try requireDiscoveryCredentials(settings: settings, keychain: store.keychain)
            return try await performDiscovery(settings: settings, store: store)
        }
        discoveryTask = task
        defer { if identity == generation { discoveryTask = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        guard identity == generation else { throw CancellationError() }
        return result
    }

    private func performDiscovery(settings: AppSettings, store: LocalFirstActualStore) async throws -> BudgetDiscovery {
        let identity = generation
        let budgets = AppBudgetList.unique(
            try await store.loadBudgets(serverURLString: settings.localFirstServerURLString)
        )
        try Task.checkCancellation()
        guard identity == generation else { throw CancellationError() }
        guard let selectedBudgetID = settings.selectedBudgetID,
              let selected = budgets.first(where: { $0.syncID == selectedBudgetID }) else {
            return BudgetDiscovery(budgets: budgets, selectedBudget: nil, selectedIsOpen: false, credentialError: nil)
        }
        var credentialError: KeychainReadError?
        if !store.isOpen(budgetID: selectedBudgetID) {
            credentialError = try await store.openBudget(
                selected, serverURLString: settings.localFirstServerURLString
            )
        }
        try Task.checkCancellation()
        guard identity == generation else { throw CancellationError() }
        return BudgetDiscovery(
            budgets: budgets,
            selectedBudget: selected,
            selectedIsOpen: store.isOpen(budgetID: selectedBudgetID),
            credentialError: credentialError
        )
    }
}
