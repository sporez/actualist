import Foundation
import Observation

/// Review state for a matching `delete-transaction` rule.
///
/// Create-flow review only blocks save. Edit-flow confirmation tombstones
/// through the existing delete seam. The editor view model must not grow a
/// second delete state machine.
@MainActor
@Observable
final class TransactionRuleDeleteReview {
    enum Presentation: Equatable {
        case none
        case review
        case blocked
    }

    private(set) var presentation: Presentation = .none

    var blocksSave: Bool { presentation != .none }
    var isReviewPresented: Bool { presentation == .review }

    func consider(_ preview: TransactionRulePreview) {
        presentation = preview.deletesTransaction ? .review : .none
    }

    func dismissReview() {
        if presentation == .review {
            presentation = .blocked
        }
    }

    func cancel() {
        presentation = .none
    }

    func confirmDeletion(
        transactionID: String?,
        accountID: String?,
        date: Date,
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        didDelete: @escaping () async -> Void
    ) async -> String? {
        guard presentation != .none else { return nil }
        presentation = .none
        guard let transactionID, let accountID else {
            return nil
        }
        let snapshot = ActualTransaction(
            id: transactionID,
            account: accountID,
            date: RuleEditorDraftState.sharedDateFormatter.string(from: date),
            amount: nil,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: nil,
            notes: nil,
            cleared: nil
        )
        do {
            _ = try await repository.deleteTransactionAndRefresh(
                snapshot,
                budgetID: budgetID,
                didDelete: didDelete
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
