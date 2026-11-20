import Foundation
import Observation

/// The leading swipe action on a transaction row, chosen from its status.
enum TransactionClearedSwipeAction: Equatable {
    case clear
    case unclear
    case unlock

    init(status: TransactionRowSemantics.Status) {
        switch status {
        case .uncleared: self = .clear
        case .cleared: self = .unclear
        case .reconciled: self = .unlock
        }
    }

    var title: String {
        switch self {
        case .clear: "Clear"
        case .unclear: "Unclear"
        case .unlock: "Unlock"
        }
    }

    var systemImage: String {
        switch self {
        case .clear: "c.circle.fill"
        case .unclear: "c.circle"
        case .unlock: "lock.open.fill"
        }
    }

    /// Split pieces share their parent's cleared state, and Actual's mobile list
    /// offers no toggle on them; rows without an id cannot be written.
    static func isAvailable(for transaction: ActualTransaction) -> Bool {
        TransactionSelectionIdentity(transaction: transaction)?.role == .root
    }
}

/// Toggles one row's cleared state from a swipe. Like Actual's mobile list
/// (`AccountTransactions.onToggleTransactionCleared`), an unlocked row goes
/// through the batch Clear command for that one id, and a reconciled row asks
/// before it is unlocked.
@MainActor
@Observable
final class TransactionClearedSwipeCoordinator {
    struct UnlockRequest: Identifiable, Hashable, Sendable {
        let transaction: ActualTransaction
        let budgetID: String
        let presentation: ReconciledTransactionMutationPresentation

        var id: String { transaction.rowID }
    }

    private(set) var pendingTransactionID: String?
    var unlockRequest: UnlockRequest?
    private(set) var errorMessage: String?
    private(set) var successFeedback = 0
    @ObservationIgnored private var generation = OperationGeneration()

    /// The swipe is not a feed selection, so the context ignores the feed's
    /// filters. A category feed is a slice of Spending; the context only binds
    /// the review to its commit.
    static func context(
        scope: TransactionFeedScope,
        budgetID: String?,
        sessionGeneration: Int
    ) -> TransactionSelectionContext? {
        guard let budgetID else { return nil }
        return TransactionSelectionContext(
            budgetID: budgetID,
            sessionGeneration: sessionGeneration,
            scope: scope.queryScope ?? .spending,
            querySignature: TransactionFeedQuery().signature
        )
    }

    func toggle(
        _ transaction: ActualTransaction,
        context: TransactionSelectionContext?,
        batchRepository: any TransactionBatchRepositoryProtocol,
        transactionRepository: any TransactionRepositoryProtocol,
        onCommitted: @MainActor (TransactionBatchOutcome) -> Void
    ) async {
        guard pendingTransactionID == nil, unlockRequest == nil,
              let context,
              let identity = TransactionSelectionIdentity(transaction: transaction),
              identity.role == .root else { return }
        let request = generation.begin()
        pendingTransactionID = transaction.rowID
        errorMessage = nil
        defer { if generation.isCurrent(request, requiringNotCancelled: false) { pendingTransactionID = nil } }
        do {
            if transaction.reconciled {
                let review = try await transactionRepository.reconciledMutationReview(
                    budgetID: context.budgetID,
                    transactionID: identity.transactionID
                )
                guard generation.isCurrent(request, requiringNotCancelled: false) else { return }
                if let review, review.targetRequiresUnlock {
                    unlockRequest = UnlockRequest(
                        transaction: transaction,
                        budgetID: context.budgetID,
                        presentation: .make(review: review, intent: .unlock)
                    )
                    return
                }
            }
            let review = try await batchRepository.reviewTransactionBatch(
                context: context,
                intent: .clear,
                selections: [identity]
            )
            guard generation.isCurrent(request, requiringNotCancelled: false) else { return }
            guard review.canSubmit, review.eligibleCount == 1 else {
                errorMessage = review.dispositions.lazy.compactMap(\.explanation).first
                    ?? "This transaction cannot be cleared."
                return
            }
            let outcome = try await batchRepository.commitTransactionBatch(
                review: review,
                authorization: review.authorization
            )
            onCommitted(outcome)
            guard generation.isCurrent(request, requiringNotCancelled: false) else { return }
            successFeedback &+= 1
        } catch {
            guard generation.isCurrent(request, requiringNotCancelled: false) else { return }
            errorMessage = error.userFacingMessage ?? error.localizedDescription
        }
    }

    func confirmUnlock(
        transactionRepository: any TransactionRepositoryProtocol,
        onUnlocked: @MainActor () -> Void
    ) async {
        guard pendingTransactionID == nil, let unlockRequest,
              let transactionID = unlockRequest.transaction.id else { return }
        let request = generation.begin()
        self.unlockRequest = nil
        pendingTransactionID = unlockRequest.transaction.rowID
        errorMessage = nil
        defer { if generation.isCurrent(request, requiringNotCancelled: false) { pendingTransactionID = nil } }
        do {
            _ = try await transactionRepository.unlockReconciledTransactionAndRefresh(
                budgetID: unlockRequest.budgetID,
                accountID: unlockRequest.transaction.account,
                transactionID: transactionID
            )
            onUnlocked()
            guard generation.isCurrent(request, requiringNotCancelled: false) else { return }
            successFeedback &+= 1
        } catch {
            guard generation.isCurrent(request, requiringNotCancelled: false) else { return }
            errorMessage = error.userFacingMessage ?? error.localizedDescription
        }
    }

    /// Drops pending work, for a budget switch: a late result changes nothing.
    func reset() {
        generation.begin()
        pendingTransactionID = nil
        unlockRequest = nil
        errorMessage = nil
    }
}

private extension TransactionBatchDisposition {
    var explanation: String? {
        switch self {
        case .skipped(let reason), .blocked(let reason): reason.explanation
        case .eligible, .requiresAuthorization: nil
        }
    }
}
