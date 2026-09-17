import Foundation
import Observation

@MainActor
@Observable
final class TransactionEditorMutationCoordinator {
    enum State: Hashable, Sendable {
        case idle
        case loadingUnlock
        case reviewing(ReconciledTransactionMutationPresentation)
        case confirming(ReconciledTransactionMutationPresentation)
        case unlocking(ReconciledTransactionMutationPresentation)
    }

    enum Outcome: Equatable {
        case saved
        case unlocked
        case awaitingReview
        case failed(String)
        case cancelled
    }

    let transactionID: String?
    let originalAccountID: String?
    let originalMonth: String?

    private(set) var state: State = .idle
    private(set) var isTransactionReconciled: Bool
    private let submission = TransactionEditorSubmissionCoordinator()
    @ObservationIgnored private var generation = 0

    init(transaction: ActualTransaction?) {
        transactionID = transaction?.id
        originalAccountID = transaction?.account
        originalMonth = transaction?.date.actualYearMonth
        isTransactionReconciled = transaction?.reconciled ?? false
    }

    var isEditing: Bool {
        originalAccountID != nil
    }

    var submissionState: TransactionSubmissionState {
        submission.submissionState
    }

    var isSubmitting: Bool {
        submission.isSubmitting
    }

    var presentation: ReconciledTransactionMutationPresentation? {
        switch state {
        case .reviewing(let presentation):
            presentation
        case .idle, .loadingUnlock, .confirming, .unlocking:
            nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .loadingUnlock, .confirming, .unlocking:
            true
        case .idle, .reviewing:
            submission.isSubmitting
        }
    }

    func submit(
        validation: TransactionSplitValidation,
        draft: TransactionDraft?,
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        authorization: ReconciledTransactionMutationAuthorization? = nil
    ) async -> Outcome {
        switch submission.preflight(
            validation: validation,
            draft: draft,
            editingIdentity: editingIdentity
        ) {
        case .proceed(let identity, let draft):
            switch await submission.execute(
                editingIdentity: identity,
                draft: draft,
                budgetID: budgetID,
                reconciliationAuthorization: authorization,
                repository: repository
            ) {
            case .succeeded:
                state = .idle
                return .saved
            case .requiresReconciledReview(let review):
                present(review, intent: .update)
                return .awaitingReview
            case .failed(let message):
                return .failed(message)
            case .cancelled:
                return .cancelled
            }
        case .rejectedSplitOverflow(let message):
            return .failed(message)
        case .rejectedSplitMismatch,
             .rejectedInvalidDraft,
             .rejectedAlreadySubmitting,
             .rejectedInvalidEditingIdentity:
            return .cancelled
        }
    }

    func confirmRuleDelete(
        date: Date,
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        deleteReview: TransactionRuleDeleteReview,
        authorization: ReconciledTransactionMutationAuthorization? = nil,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async -> Outcome {
        switch await deleteReview.confirmDeletion(
            transactionID: transactionID,
            accountID: originalAccountID,
            date: date,
            budgetID: budgetID,
            reconciliationAuthorization: authorization,
            repository: repository,
            didDelete: didDelete
        ) {
        case .success:
            state = .idle
            return .saved
        case .failure(let error):
            if case .confirmationRequired(let review) = error as? ReconciledTransactionMutationError {
                present(review, intent: .ruleDelete)
                return .awaitingReview
            }
            return .failed(error.userFacingMessage ?? error.localizedDescription)
        }
    }

    func requestClearedChange(
        _ isCleared: Bool,
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async throws -> Bool {
        guard !isCleared, isTransactionReconciled,
              let transactionID else {
            return isCleared
        }
        generation &+= 1
        let requestGeneration = generation
        state = .loadingUnlock
        do {
            let review = try await repository.reconciledMutationReview(
                budgetID: budgetID,
                transactionID: transactionID
            )
            guard generation == requestGeneration else { return true }
            guard let review, review.targetRequiresUnlock else {
                isTransactionReconciled = false
                state = .idle
                return false
            }
            present(review, intent: .unlock)
            return true
        } catch {
            guard generation == requestGeneration else { return true }
            state = .idle
            throw error
        }
    }

    func confirmPending(
        validation: TransactionSplitValidation,
        draft: TransactionDraft?,
        date: Date,
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        deleteReview: TransactionRuleDeleteReview,
        didMutate: @escaping @MainActor @Sendable () async -> Void
    ) async -> Outcome {
        guard let presentation = pendingPresentation else { return .cancelled }
        let outcome: Outcome
        switch presentation.intent {
        case .update:
            outcome = await submit(
                validation: validation,
                draft: draft,
                budgetID: budgetID,
                repository: repository,
                authorization: presentation.review.authorization
            )
        case .ruleDelete:
            outcome = await confirmRuleDelete(
                date: date,
                budgetID: budgetID,
                repository: repository,
                deleteReview: deleteReview,
                authorization: presentation.review.authorization,
                didDelete: didMutate
            )
        case .unlock:
            guard let transactionID, let originalAccountID else { return .cancelled }
            state = .unlocking(presentation)
            do {
                _ = try await repository.unlockReconciledTransactionAndRefresh(
                    budgetID: budgetID,
                    accountID: originalAccountID,
                    transactionID: transactionID
                )
                isTransactionReconciled = false
                state = .idle
                await didMutate()
                outcome = .unlocked
            } catch {
                outcome = .failed(error.userFacingMessage ?? error.localizedDescription)
            }
        case .delete:
            outcome = .cancelled
        }
        if case .confirming = state {
            state = .reviewing(presentation)
        } else if case .unlocking = state {
            state = .reviewing(presentation)
        }
        return outcome
    }

    func beginConfirmation() -> Bool {
        guard case .reviewing(let presentation) = state else { return false }
        state = .confirming(presentation)
        return true
    }

    func dismissReview() {
        guard case .reviewing = state else { return }
        generation &+= 1
        state = .idle
    }

    func cancel() {
        generation &+= 1
        submission.cancel()
        state = .idle
    }

    private var editingIdentity: TransactionEditorSubmissionCoordinator.EditingIdentity? {
        if !isEditing { return .creating }
        guard let transactionID, let originalAccountID, let originalMonth else { return nil }
        return .updating(
            transactionID: transactionID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth
        )
    }

    private var pendingPresentation: ReconciledTransactionMutationPresentation? {
        switch state {
        case .reviewing(let presentation),
             .confirming(let presentation),
             .unlocking(let presentation):
            presentation
        case .idle, .loadingUnlock:
            nil
        }
    }

    private func present(
        _ review: ReconciledTransactionMutationReview,
        intent: ReconciledTransactionMutationIntent
    ) {
        state = .reviewing(.make(review: review, intent: intent))
    }
}
