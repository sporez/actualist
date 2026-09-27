import Foundation
import Observation

enum AccountLifecycleRecoveryState: Hashable, Sendable {
    case rename(AccountRenameDraft)
    case reopen(AccountReopenSession)
    case review(AccountLifecycleReviewRequest)
}

enum AccountLifecycleState: Hashable, Sendable {
    case idle
    case renaming(AccountRenameDraft)
    case submittingRename(AccountRenameDraft)
    case reopening(AccountReopenSession)
    case submittingReopen(AccountReopenSession)
    case loadingReview(AccountLifecycleReviewRequest)
    case reviewing(AccountLifecycleReview)
    case completed(AccountLifecycleOutcome)
    case failed(AccountLifecycleRecoveryState, message: String)
}

@MainActor
@Observable
final class AccountLifecycleCoordinator {
    private(set) var state: AccountLifecycleState = .idle
    private(set) var isPrivacyModeEnabled: Bool

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(isPrivacyModeEnabled: Bool = false) {
        self.isPrivacyModeEnabled = isPrivacyModeEnabled
    }

    var renameDraft: AccountRenameDraft? {
        switch state {
        case .renaming(let draft), .submittingRename(let draft):
            draft
        case .failed(.rename(let draft), _):
            draft
        default:
            nil
        }
    }

    var reopenSession: AccountReopenSession? {
        switch state {
        case .reopening(let session), .submittingReopen(let session):
            session
        case .failed(.reopen(let session), _):
            session
        default:
            nil
        }
    }

    var review: AccountLifecycleReview? {
        switch state {
        case .reviewing(let review):
            review
        default:
            nil
        }
    }

    var isSubmitting: Bool {
        switch state {
        case .submittingRename, .submittingReopen:
            true
        default:
            false
        }
    }

    var errorMessage: String? {
        guard case .failed(_, let message) = state else { return nil }
        return message
    }

    func beginRename(
        identity: AccountLifecycleIdentity,
        account: AccountLifecycleAccount,
        existingAccounts: [AccountLifecycleAccount]
    ) {
        guard !isPrivacyModeEnabled, !isSubmitting else { return }
        cancelOperation()
        state = .renaming(AccountRenameDraft(
            identity: identity,
            account: account,
            existingAccounts: existingAccounts,
            name: account.name,
            validationMessage: nil
        ))
    }

    func updateRenameName(_ name: String) {
        guard case .renaming(var draft) = state else { return }
        draft.name = name
        draft.validationMessage = nil
        state = .renaming(draft)
    }

    @discardableResult
    func submitRename(
        repository: any AccountLifecycleRepositoryProtocol,
        didMutate: @escaping @MainActor (AccountLifecycleOutcome) -> Void
    ) -> Task<Void, Never>? {
        guard !isPrivacyModeEnabled, case .renaming(var draft) = state else { return nil }
        guard let command = draft.command else {
            draft.validationMessage = draft.validationError?.localizedDescription
            state = .renaming(draft)
            return nil
        }
        let requestGeneration = beginOperation()
        state = .submittingRename(draft)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.renameAccountAndRefresh(
                    budgetID: draft.identity.budgetID,
                    command: command
                )
                guard isCurrent(requestGeneration, identity: draft.identity) else { return }
                switch result {
                case .applied(let outcome):
                    state = .completed(outcome)
                    finishOperation(requestGeneration)
                    didMutate(outcome)
                    return
                case .noChange(let outcome):
                    state = .completed(outcome)
                case .reviewChanged(let review):
                    state = .reviewing(review)
                }
                finishOperation(requestGeneration)
            } catch {
                guard isCurrent(requestGeneration, identity: draft.identity) else { return }
                state = .failed(.rename(draft), message: message(for: error))
                finishOperation(requestGeneration)
            }
        }
        return operationTask
    }

    func beginReopen(
        identity: AccountLifecycleIdentity,
        account: AccountLifecycleAccount
    ) {
        guard !isPrivacyModeEnabled, !isSubmitting else { return }
        cancelOperation()
        state = .reopening(AccountReopenSession(identity: identity, account: account))
    }

    @discardableResult
    func confirmReopen(
        repository: any AccountLifecycleRepositoryProtocol,
        didMutate: @escaping @MainActor (AccountLifecycleOutcome) -> Void
    ) -> Task<Void, Never>? {
        guard !isPrivacyModeEnabled, case .reopening(let session) = state else { return nil }
        let requestGeneration = beginOperation()
        state = .submittingReopen(session)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.reopenAccountAndRefresh(
                    budgetID: session.identity.budgetID,
                    command: session.command
                )
                guard isCurrent(requestGeneration, identity: session.identity) else { return }
                switch result {
                case .applied(let outcome):
                    state = .completed(outcome)
                    finishOperation(requestGeneration)
                    didMutate(outcome)
                    return
                case .noChange(let outcome):
                    state = .completed(outcome)
                case .reviewChanged(let review):
                    state = .reviewing(review)
                }
                finishOperation(requestGeneration)
            } catch {
                guard isCurrent(requestGeneration, identity: session.identity) else { return }
                state = .failed(.reopen(session), message: message(for: error))
                finishOperation(requestGeneration)
            }
        }
        return operationTask
    }

    func loadReview(
        request: AccountLifecycleReviewRequest,
        repository: any AccountLifecycleRepositoryProtocol
    ) {
        guard !isPrivacyModeEnabled, !isSubmitting else { return }
        let requestGeneration = beginOperation()
        state = .loadingReview(request)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let review = try await repository.accountLifecycleReview(request: request)
                let identity = AccountLifecycleIdentity(
                    budgetID: request.budgetID,
                    accountID: request.accountID
                )
                guard isCurrent(requestGeneration, identity: identity) else { return }
                state = .reviewing(review)
                finishOperation(requestGeneration)
            } catch {
                let identity = AccountLifecycleIdentity(
                    budgetID: request.budgetID,
                    accountID: request.accountID
                )
                guard isCurrent(requestGeneration, identity: identity) else { return }
                state = .failed(.review(request), message: message(for: error))
                finishOperation(requestGeneration)
            }
        }
    }

    func retry(repository: any AccountLifecycleRepositoryProtocol) {
        guard !isPrivacyModeEnabled, case .failed(let recovery, _) = state else { return }
        switch recovery {
        case .rename(let draft):
            state = .renaming(draft)
        case .reopen(let session):
            state = .reopening(session)
        case .review(let request):
            loadReview(request: request, repository: repository)
        }
    }

    func contextDidChange(to identity: AccountLifecycleIdentity?) {
        guard stateIdentity != identity else { return }
        cancel()
    }

    func updatePrivacyMode(_ isEnabled: Bool) {
        guard isPrivacyModeEnabled != isEnabled else { return }
        isPrivacyModeEnabled = isEnabled
        if isEnabled {
            cancel()
        }
    }

    func cancel() {
        cancelOperation()
        state = .idle
    }

    private var stateIdentity: AccountLifecycleIdentity? {
        switch state {
        case .renaming(let draft), .submittingRename(let draft):
            draft.identity
        case .reopening(let session), .submittingReopen(let session):
            session.identity
        case .loadingReview(let request):
            AccountLifecycleIdentity(budgetID: request.budgetID, accountID: request.accountID)
        case .reviewing(let review):
            AccountLifecycleIdentity(
                budgetID: review.identity.budgetID,
                accountID: review.identity.accountID
            )
        case .failed(let recovery, _):
            switch recovery {
            case .rename(let draft): draft.identity
            case .reopen(let session): session.identity
            case .review(let request):
                AccountLifecycleIdentity(budgetID: request.budgetID, accountID: request.accountID)
            }
        case .idle, .completed:
            nil
        }
    }

    private func beginOperation() -> Int {
        operationTask?.cancel()
        generation &+= 1
        return generation
    }

    private func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        generation &+= 1
    }

    private func finishOperation(_ requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        operationTask = nil
    }

    private func isCurrent(
        _ requestGeneration: Int,
        identity: AccountLifecycleIdentity
    ) -> Bool {
        !Task.isCancelled && generation == requestGeneration && stateIdentity == identity
    }

    private func message(for error: Error) -> String {
        if let commandError = error as? AccountLifecycleCommandError {
            return commandError.localizedDescription
        }
        return error.userFacingMessage ?? error.localizedDescription
    }
}
