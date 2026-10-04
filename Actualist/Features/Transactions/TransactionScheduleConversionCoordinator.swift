import Foundation
import Observation

struct TransactionScheduleConversionReviewContent: Hashable, Sendable {
    let review: ScheduleConversionReview
    let dateText: String
    let amountText: String
    let accountText: String
    let payeeText: String
    let categoryText: String
    let transactionTypeText: String
}

struct TransactionScheduleConversionOutcome: Hashable, Sendable {
    let context: ScheduleMutationSessionContext
    let receipt: ScheduleConversionReceipt

    func belongsToSession(budgetID: String?, generation: Int) -> Bool {
        context.budgetID == budgetID && context.generation == generation
    }
}

enum TransactionScheduleConversionState: Hashable, Sendable {
    case idle
    case loading
    case review(TransactionScheduleConversionReviewContent)
    case submitting(TransactionScheduleConversionReviewContent)
    case committed(ScheduleConversionReceipt)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .loading, .submitting: true
        case .idle, .review, .committed, .failed: false
        }
    }

    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }
}

@MainActor
@Observable
final class TransactionScheduleConversionCoordinator {
    private(set) var state: TransactionScheduleConversionState = .idle
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    var isPresented: Bool {
        get { state != .idle }
        set { if !newValue { _ = cancel() } }
    }

    func beginReview(
        budgetID: String,
        expectedGeneration: Int,
        entryPoint: TransactionScheduleConversionEntryPoint,
        currency: BudgetCurrency,
        isPrivacyModeEnabled: Bool,
        repository: any TransactionScheduleConversionRepositoryProtocol
    ) {
        guard !state.isBusy else { return }
        let request = beginRequest()
        let context: ScheduleMutationSessionContext
        do {
            context = try repository.scheduleConversionSessionContext(budgetID: budgetID)
            guard context.budgetID == budgetID, context.generation == expectedGeneration else {
                state = .failed("The selected budget changed. Reopen the transaction and try again.")
                finish(request)
                return
            }
        } catch {
            state = .failed(message(for: error))
            finish(request)
            return
        }

        state = .loading
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let review = try await repository.scheduleConversionReview(
                    budgetID: budgetID,
                    transactionID: entryPoint.transactionID,
                    asOfDayID: entryPoint.asOfDayID
                )
                try Task.checkCancellation()
                guard isCurrent(request) else { return }
                guard review.context == context,
                      review.sourceTransactionID == entryPoint.transactionID,
                      review.asOfDayID == entryPoint.asOfDayID,
                      let source = review.source,
                      source == entryPoint.source else {
                    state = .failed("The transaction changed while its review was loading. Review it again.")
                    finish(request)
                    return
                }
                state = .review(TransactionScheduleConversionReviewContent(
                    review: review,
                    dateText: SchedulePresentation.dateLabel(source.date),
                    amountText: SchedulePresentation.amountLabel(
                        .exact(source.amount ?? 0),
                        currency: currency,
                        privacyEnabled: isPrivacyModeEnabled,
                        seed: "schedule-conversion-\(entryPoint.transactionID)"
                    ),
                    accountText: isPrivacyModeEnabled ? "Selected account" : entryPoint.names.account,
                    payeeText: isPrivacyModeEnabled ? "Payee hidden" : entryPoint.names.payee,
                    categoryText: isPrivacyModeEnabled ? "Category hidden" : entryPoint.names.category,
                    transactionTypeText: source.isParent
                        ? "Split transaction · \(source.subtransactions.count) parts"
                        : "Single transaction"
                ))
                finish(request)
            } catch {
                guard isCurrent(request) else { return }
                state = .failed(message(for: error))
                finish(request)
            }
        }
    }

    func confirm(
        repository: any TransactionScheduleConversionRepositoryProtocol,
        onCommitted: @escaping @MainActor (TransactionScheduleConversionOutcome) -> Void = { _ in }
    ) {
        guard case .review(let content) = state,
              !state.isBusy,
              (try? repository.scheduleConversionSessionContext(
                  budgetID: content.review.context.budgetID
              )) == content.review.context else { return }
        let request = beginRequest()
        state = .submitting(content)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await repository.convertFutureTransaction(review: content.review)
                guard isCurrent(request) else { return }
                state = .committed(receipt)
                finish(request)
                onCommitted(TransactionScheduleConversionOutcome(
                    context: content.review.context,
                    receipt: receipt
                ))
            } catch {
                guard isCurrent(request) else { return }
                state = .failed(message(for: error))
                finish(request)
            }
        }
    }

    func finishCommitted() {
        guard case .committed = state else { return }
        state = .idle
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        guard !state.isSubmitting else { return nil }
        let canceled = operationTask
        canceled?.cancel()
        operationTask = nil
        generation &+= 1
        state = .idle
        return canceled
    }

    func dismissFailure() {
        guard case .failed = state else { return }
        _ = cancel()
    }

    private func beginRequest() -> Int {
        operationTask?.cancel()
        generation &+= 1
        return generation
    }

    private func finish(_ request: Int) {
        guard generation == request else { return }
        operationTask = nil
    }

    private func isCurrent(_ request: Int) -> Bool {
        generation == request && !Task.isCancelled
    }

    private func message(for error: Error) -> String {
        switch error {
        case let conversionError as ScheduleConversionError:
            switch conversionError {
            case .reviewChanged, .transactionNotFuture, .identityConflict, .unsupportedSchema:
                conversionError.errorDescription ?? conversionSaveFailed
            case .unsupportedSource(let reason):
                reason
            }
        case let localFirstError as LocalFirstError:
            // Unwrapped local-write refusals carry internal detail strings.
            if case .invalidLocalWrite = localFirstError { conversionSaveFailed }
            else { localFirstError.errorDescription ?? conversionSaveFailed }
        default:
            error.userFacingMessage ?? conversionSaveFailed
        }
    }

    private var conversionSaveFailed: String {
        "Actualist couldn't convert this transaction. Try again."
    }
}
