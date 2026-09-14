import Foundation
import Observation

struct AccountReconciliationIdentity: Hashable, Sendable {
    let budgetID: String
    let accountID: String
}

struct AccountReconciliationTargetEntry: Hashable, Sendable {
    let identity: AccountReconciliationIdentity
    let snapshot: AccountReconciliationSnapshot
    var input: AccountReconciliationAmountInput
    var validationMessage: String?
}

struct AccountReconciliationSession: Hashable, Sendable {
    let identity: AccountReconciliationIdentity
    let targetBalance: Int
    let snapshot: AccountReconciliationSnapshot

    func replacingSnapshot(_ snapshot: AccountReconciliationSnapshot) -> Self {
        Self(identity: identity, targetBalance: targetBalance, snapshot: snapshot)
    }
}

struct AccountReconciliationFailure: Hashable, Sendable {
    let identity: AccountReconciliationIdentity
    let session: AccountReconciliationSession?
    let message: String
}

@MainActor
@Observable
final class AccountReconciliationCoordinator {
    enum State: Hashable, Sendable {
        case idle
        case loadingStart(AccountReconciliationIdentity)
        case enteringTarget(AccountReconciliationTargetEntry)
        case reconciling(AccountReconciliationSession)
        case submitting(AccountReconciliationSession, AccountReconciliationAction)
        case failed(AccountReconciliationFailure)
    }

    private(set) var state: State = .idle
    private(set) var currency: BudgetCurrency = .usd

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var presentsTargetSheet: Bool {
        switch state {
        case .loadingStart, .enteringTarget:
            true
        case .failed(let failure):
            failure.session == nil
        case .idle, .reconciling, .submitting:
            false
        }
    }

    var targetEntry: AccountReconciliationTargetEntry? {
        guard case .enteringTarget(let entry) = state else { return nil }
        return entry
    }

    var startErrorMessage: String? {
        guard case .failed(let failure) = state, failure.session == nil else { return nil }
        return failure.message
    }

    var activeSession: AccountReconciliationSession? {
        switch state {
        case .reconciling(let session), .submitting(let session, _):
            session
        case .failed(let failure):
            failure.session
        case .idle, .loadingStart, .enteringTarget:
            nil
        }
    }

    var submittingAction: AccountReconciliationAction? {
        guard case .submitting(_, let action) = state else { return nil }
        return action
    }

    var activeErrorMessage: String? {
        guard case .failed(let failure) = state, failure.session != nil else { return nil }
        return failure.message
    }

    func start(
        identity: AccountReconciliationIdentity,
        currency: BudgetCurrency,
        repository: any AccountRepositoryProtocol
    ) {
        guard case .idle = state else { return }
        self.currency = currency
        let requestGeneration = beginOperation()
        state = .loadingStart(identity)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await repository.accountReconciliationSnapshot(
                    budgetID: identity.budgetID,
                    accountID: identity.accountID
                )
                guard isCurrent(requestGeneration, identity: identity) else { return }
                guard case .available = snapshot.capability else {
                    if case .unavailable(let reason) = snapshot.capability {
                        state = .failed(AccountReconciliationFailure(
                            identity: identity,
                            session: nil,
                            message: reason.message
                        ))
                    }
                    finishOperation(requestGeneration)
                    return
                }
                state = .enteringTarget(AccountReconciliationTargetEntry(
                    identity: identity,
                    snapshot: snapshot,
                    input: AccountReconciliationAmountInput(
                        minorUnits: snapshot.clearedBalance,
                        currency: currency
                    ),
                    validationMessage: nil
                ))
                finishOperation(requestGeneration)
            } catch {
                guard isCurrent(requestGeneration, identity: identity) else { return }
                state = .failed(AccountReconciliationFailure(
                    identity: identity,
                    session: nil,
                    message: message(for: error)
                ))
                finishOperation(requestGeneration)
            }
        }
    }

    func updateTargetText(_ text: String) {
        guard case .enteringTarget(var entry) = state else { return }
        entry.input.text = text
        entry.validationMessage = nil
        state = .enteringTarget(entry)
    }

    func useLastSyncedBalance() {
        guard case .enteringTarget(var entry) = state,
              let balance = entry.snapshot.lastSyncedBalance else {
            return
        }
        entry.input = AccountReconciliationAmountInput(minorUnits: balance, currency: currency)
        entry.validationMessage = nil
        state = .enteringTarget(entry)
    }

    func confirmTarget(locale: Locale = .current) {
        guard case .enteringTarget(var entry) = state else { return }
        switch entry.input.minorUnits(currency: currency, locale: locale) {
        case .success(let targetBalance):
            state = .reconciling(AccountReconciliationSession(
                identity: entry.identity,
                targetBalance: targetBalance,
                snapshot: entry.snapshot
            ))
        case .failure(let error):
            entry.validationMessage = validationMessage(for: error)
            state = .enteringTarget(entry)
        }
    }

    func refreshIfActive(
        identity: AccountReconciliationIdentity,
        repository: any AccountRepositoryProtocol
    ) {
        guard let session = activeSession,
              session.identity == identity,
              submittingAction == nil else {
            return
        }
        perform(.refresh, session: session, repository: repository, didMutate: {})
    }

    func createAdjustment(
        repository: any AccountRepositoryProtocol,
        didMutate: @escaping @MainActor () -> Void
    ) {
        guard let session = actionableSession else { return }
        perform(.createAdjustment, session: session, repository: repository, didMutate: didMutate)
    }

    func lockTransactions(
        repository: any AccountRepositoryProtocol,
        didMutate: @escaping @MainActor () -> Void
    ) {
        guard let session = actionableSession else { return }
        perform(.lockTransactions, session: session, repository: repository, didMutate: didMutate)
    }

    func exit(
        repository: any AccountRepositoryProtocol,
        didMutate: @escaping @MainActor () -> Void
    ) {
        guard let session = actionableSession else { return }
        perform(.exit, session: session, repository: repository, didMutate: didMutate)
    }

    func cancel() {
        operationTask?.cancel()
        operationTask = nil
        generation &+= 1
        state = .idle
    }

    func targetSheetDismissed() {
        guard presentsTargetSheet else { return }
        cancel()
    }

    func reconcileContext(_ identity: AccountReconciliationIdentity?) {
        guard stateIdentity != identity else { return }
        cancel()
    }

    func targetPresentation(privacyModeEnabled: Bool) -> AccountReconciliationTargetPresentation? {
        guard let targetEntry else { return nil }
        return AccountReconciliationPresentation.target(
            entry: targetEntry,
            currency: currency,
            privacyModeEnabled: privacyModeEnabled
        )
    }

    func panelPresentation(privacyModeEnabled: Bool) -> AccountReconciliationPanelPresentation? {
        guard let activeSession else { return nil }
        return AccountReconciliationPresentation.panel(
            session: activeSession,
            submittingAction: submittingAction,
            errorMessage: activeErrorMessage,
            currency: currency,
            privacyModeEnabled: privacyModeEnabled
        )
    }

    private var actionableSession: AccountReconciliationSession? {
        switch state {
        case .reconciling(let session):
            session
        case .failed(let failure):
            failure.session
        case .idle, .loadingStart, .enteringTarget, .submitting:
            nil
        }
    }

    private var stateIdentity: AccountReconciliationIdentity? {
        switch state {
        case .loadingStart(let identity):
            identity
        case .enteringTarget(let entry):
            entry.identity
        case .reconciling(let session), .submitting(let session, _):
            session.identity
        case .failed(let failure):
            failure.identity
        case .idle:
            nil
        }
    }

    private func perform(
        _ action: AccountReconciliationAction,
        session: AccountReconciliationSession,
        repository: any AccountRepositoryProtocol,
        didMutate: @escaping @MainActor () -> Void
    ) {
        let requestGeneration = beginOperation()
        state = .submitting(session, action)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: AccountReconciliationMutationResult
                switch action {
                case .refresh:
                    let snapshot = try await repository.accountReconciliationSnapshot(
                        budgetID: session.identity.budgetID,
                        accountID: session.identity.accountID
                    )
                    result = AccountReconciliationMutationResult(
                        snapshot: snapshot,
                        changed: ChangedResources(accounts: [], months: [], transactions: [])
                    )
                case .createAdjustment:
                    result = try await repository.createReconciliationAdjustmentAndRefresh(
                        budgetID: session.identity.budgetID,
                        accountID: session.identity.accountID,
                        targetBalance: session.targetBalance
                    )
                case .lockTransactions:
                    result = try await repository.finishReconciliationAndRefresh(
                        budgetID: session.identity.budgetID,
                        accountID: session.identity.accountID,
                        targetBalance: session.targetBalance
                    )
                case .exit:
                    result = try await repository.exitReconciliationAndRefresh(
                        budgetID: session.identity.budgetID,
                        accountID: session.identity.accountID
                    )
                }
                guard isCurrent(requestGeneration, identity: session.identity) else { return }
                if !result.changed.accounts.isEmpty
                    || !result.changed.months.isEmpty
                    || !result.changed.transactions.isEmpty {
                    didMutate()
                }
                switch action {
                case .lockTransactions, .exit:
                    state = .idle
                case .refresh, .createAdjustment:
                    state = .reconciling(session.replacingSnapshot(result.snapshot))
                }
                finishOperation(requestGeneration)
            } catch {
                guard isCurrent(requestGeneration, identity: session.identity) else { return }
                let currentSession = await refreshedSessionAfterConflict(
                    error: error,
                    session: session,
                    repository: repository,
                    requestGeneration: requestGeneration
                )
                guard isCurrent(requestGeneration, identity: session.identity) else { return }
                state = .failed(AccountReconciliationFailure(
                    identity: session.identity,
                    session: currentSession,
                    message: message(for: error)
                ))
                finishOperation(requestGeneration)
            }
        }
    }

    private func refreshedSessionAfterConflict(
        error: Error,
        session: AccountReconciliationSession,
        repository: any AccountRepositoryProtocol,
        requestGeneration: Int
    ) async -> AccountReconciliationSession {
        guard error as? AccountReconciliationCommandError == .balanceChanged,
              isCurrent(requestGeneration, identity: session.identity),
              let snapshot = try? await repository.accountReconciliationSnapshot(
                budgetID: session.identity.budgetID,
                accountID: session.identity.accountID
              ),
              isCurrent(requestGeneration, identity: session.identity) else {
            return session
        }
        return session.replacingSnapshot(snapshot)
    }

    private func beginOperation() -> Int {
        operationTask?.cancel()
        generation &+= 1
        return generation
    }

    private func finishOperation(_ requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        operationTask = nil
    }

    private func isCurrent(
        _ requestGeneration: Int,
        identity: AccountReconciliationIdentity
    ) -> Bool {
        !Task.isCancelled && generation == requestGeneration && stateIdentity == identity
    }

    private func validationMessage(
        for error: AccountReconciliationAmountInput.ValidationError
    ) -> String {
        switch error {
        case .empty:
            "Enter the balance shown by your bank."
        case .invalid:
            "Enter a valid balance."
        case .tooManyFractionDigits:
            "This balance has more decimal places than the budget currency supports."
        case .outOfRange:
            "This balance is too large."
        }
    }

    private func message(for error: Error) -> String {
        guard let commandError = error as? AccountReconciliationCommandError else {
            return error.userFacingMessage ?? error.localizedDescription
        }
        switch commandError {
        case .unavailable(let reason):
            return reason.message
        case .differenceOverflow:
            return "The balance difference is too large."
        case .alreadyBalanced:
            return "This account is already balanced."
        case .balanceChanged:
            return "The cleared balance changed. Review the new difference before locking."
        case .transactionNotFound:
            return "This transaction is no longer available."
        }
    }
}
