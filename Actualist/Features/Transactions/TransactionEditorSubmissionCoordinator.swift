import Foundation
import Observation

/// Submission lifecycle for `TransactionEditorSubmissionCoordinator`.
enum TransactionSubmissionState: Equatable {
    case draft
    case submitting
    case refetching
    case clean
    case failed(String)
}

/// Observable submission state machine for the transaction editor.
///
/// Owns the create-vs-update identity, duplicate-submit rejection,
/// `.submitting` → `.refetching` → `.clean` sequencing, retryable `.failed`,
/// and a generation-based stale-result guard so a late completion callback after
/// a budget switch or editor dismissal is a no-op. The editor view model
/// composes this coordinator and maps its outcomes to its broader
/// `errorMessage` surface; this type owns submission state only.
@MainActor
@Observable
final class TransactionEditorSubmissionCoordinator {
    /// The authoritative submission status the editor view reads.
    private(set) var submissionState: TransactionSubmissionState = .draft

    /// Increments on every accepted submission and on `cancel()`/`reset()`.
    /// Late `willRefetch`/`complete`/`fail` callbacks carrying a stale token
    /// are ignored so a superseded submit cannot mutate the current state.
    @ObservationIgnored
    private var generation = 0

    var isSubmitting: Bool {
        switch submissionState {
        case .submitting, .refetching:
            true
        case .draft, .clean, .failed:
            false
        }
    }

    enum EditingIdentity: Equatable, Sendable {
        case creating
        case updating(transactionID: String, originalAccountID: String, originalMonth: String)
    }

    /// Synchronous preflight outcome. `.proceed` hands back the resolved
    /// identity and draft so the caller does not force-unwrap; every rejected
    /// case leaves the state unchanged except `.rejectedSplitOverflow`, which
    /// transitions to `.failed` to mirror the prior in-line behavior.
    enum Preflight: Equatable {
        case proceed(identity: EditingIdentity, draft: TransactionDraft)
        case rejectedInvalidDraft
        case rejectedSplitMismatch
        case rejectedSplitOverflow(message: String)
        case rejectedAlreadySubmitting
        case rejectedInvalidEditingIdentity
    }

    /// The outcome of `execute(...)`.
    enum Outcome: Equatable {
        case succeeded(TransactionMutationResult?)
        case failed(message: String)
    }

    /// Validates the category-split result, the in-flight duplicate guard, the
    /// draft, and the editing identity — in that order (matching the prior
    /// in-line guard sequence). Sets `.failed` and returns
    /// `.rejectedSplitOverflow` for an overflow split; all other rejections
    /// leave the state unchanged.
    func preflight(
        validation: TransactionSplitValidation,
        draft: TransactionDraft?,
        editingIdentity: EditingIdentity?
    ) -> Preflight {
        switch validation {
        case .overflow:
            let message = "The split amounts are too large."
            submissionState = .failed(message)
            return .rejectedSplitOverflow(message: message)
        case .mismatch:
            return .rejectedSplitMismatch
        case .valid:
            break
        }

        guard !isSubmitting else {
            return .rejectedAlreadySubmitting
        }
        guard let draft else {
            return .rejectedInvalidDraft
        }
        guard let editingIdentity else {
            return .rejectedInvalidEditingIdentity
        }

        return .proceed(identity: editingIdentity, draft: draft)
    }

    /// Begins the submission (`.submitting`), runs the create/update call with
    /// a `didCreate`/`didUpdate` callback that transitions to `.refetching`,
    /// then completes to `.clean` or `.failed`. The generation token guards
    /// late callbacks from a superseded submission (see `cancel()`).
    func execute(
        editingIdentity: EditingIdentity,
        draft: TransactionDraft,
        budgetID: String,
        repository: any TransactionRepositoryProtocol
    ) async -> Outcome {
        generation += 1
        let token = generation
        submissionState = .submitting

        do {
            let result: TransactionMutationResult
            switch editingIdentity {
            case .creating:
                result = try await repository.createTransactionAndRefresh(
                    draft,
                    budgetID: budgetID
                ) { [weak self] in
                    await MainActor.run {
                        self?.transitionToRefetching(token: token)
                    }
                }
            case .updating(let transactionID, let originalAccountID, let originalMonth):
                result = try await repository.updateTransactionAndRefresh(
                    transactionID,
                    with: draft,
                    budgetID: budgetID,
                    originalAccountID: originalAccountID,
                    originalMonth: originalMonth
                ) { [weak self] in
                    await MainActor.run {
                        self?.transitionToRefetching(token: token)
                    }
                }
            }
            complete(token: token)
            return .succeeded(result)
        } catch {
            let message = error.localizedDescription
            fail(token: token, message: message)
            return .failed(message: message)
        }
    }

    /// Cancels any in-flight submission: bumps the generation so late callbacks
    /// are ignored and resets to `.draft`. Used on budget switch / dismissal.
    func cancel() {
        generation += 1
        submissionState = .draft
    }

    /// Resets to `.draft` (e.g. when preparing the editor for a new transaction).
    func reset() {
        generation += 1
        submissionState = .draft
    }

    private func transitionToRefetching(token: Int) {
        guard token == generation else { return }
        submissionState = .refetching
    }

    private func complete(token: Int) {
        guard token == generation else { return }
        submissionState = .clean
    }

    private func fail(token: Int, message: String) {
        guard token == generation else { return }
        submissionState = .failed(message)
    }
}
