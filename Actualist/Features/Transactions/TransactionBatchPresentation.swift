import Foundation
import Observation

@MainActor
@Observable
final class TransactionBatchPresentation {
    enum SheetContent: Equatable {
        case categoryPicker(context: TransactionSelectionContext)
        case review
    }

    enum CommandSheet: Equatable {
        case duplicate
        case merge
    }

    let selection = TransactionSelectionCoordinator()
    let duplicate = TransactionDuplicateCoordinator()
    let merge = TransactionMergeCoordinator()
    private(set) var sheetContent: SheetContent?
    private(set) var commandSheet: CommandSheet?
    private(set) var categoryPicker: TransactionBatchCategoryPickerWorkflow?

    var selectedCount: Int { selection.selectedCount }

    var isSheetPresented: Bool { sheetContent != nil || commandSheet != nil }

    var isSelectionMode: Bool {
        if duplicate.hidesSelectionChrome || merge.hidesSelectionChrome { return false }
        switch selection.state {
        case .selecting, .failed: return true
        case .inactive, .preparing, .reviewing, .submitting, .committed: return false
        }
    }

    var isBatchFlowActive: Bool {
        if case .inactive = selection.state { return false }
        return true
    }

    var canActOnSelection: Bool {
        guard selectedCount > 0 else { return false }
        if case .selecting = selection.state { return true }
        return false
    }

    var selectionFailureMessage: String? {
        if case .failed(_, _, let message) = selection.state { return message }
        return duplicate.failureMessage ?? merge.failureMessage
    }

    var preventsSheetDismissal: Bool {
        selection.isSubmitting || duplicate.isSubmitting || merge.isSubmitting
    }

    func enter(context: TransactionSelectionContext?) {
        guard let context else { return }
        guard !selection.isSubmitting, !duplicate.isSubmitting, !merge.isSubmitting else { return }
        endCommandFlows()
        cancelCategoryPicker()
        sheetContent = nil
        selection.enter(context: context)
    }

    func toggle(_ transaction: ActualTransaction) {
        guard !duplicate.hidesSelectionChrome, !merge.hidesSelectionChrome else { return }
        duplicate.dismissFailure()
        merge.dismissFailure()
        guard let identity = TransactionSelectionIdentity(transaction: transaction) else { return }
        selection.toggle(identity)
    }

    func contextChanged(to context: TransactionSelectionContext?) {
        guard !selection.isSubmitting, !duplicate.isSubmitting, !merge.isSubmitting else { return }
        guard context != currentSelectionContext else { return }
        endCommandFlows()
        if let context {
            selection.contextChanged(to: context)
        } else {
            selection.exit()
        }
        guard case .inactive = selection.state else { return }
        cancelCategoryPicker()
        sheetContent = nil
    }

    func sessionChanged() {
        guard !isProtectedFlow else {
            return
        }
        endCommandFlows()
        selection.exit()
        cancelCategoryPicker()
        sheetContent = nil
    }

    func feedDidDisappear() {
        guard !isProtectedFlow else {
            return
        }
        endCommandFlows()
        selection.exit()
        cancelCategoryPicker()
        sheetContent = nil
    }

    func exitSelection() {
        guard !duplicate.isSubmitting, !merge.isSubmitting,
              !duplicate.isCommitted, !merge.isCommitted else { return }
        endCommandFlows()
        selection.exit()
        cancelCategoryPicker()
        sheetContent = nil
    }

    func presentCategoryPicker(budgetID: String?, repository: any TransactionRepositoryProtocol) {
        guard canActOnSelection, !commandFlowLocksSelection, let budgetID,
              case .selecting(let context, _) = selection.state else { return }
        endCommandFlows()
        categoryPicker?.cancel()
        categoryPicker = TransactionBatchCategoryPickerWorkflow(
            budgetID: budgetID,
            repository: repository
        )
        let workflow = categoryPicker
        sheetContent = .categoryPicker(context: context)
        Task { @MainActor in await workflow?.load() }
    }

    func cancelSheet() {
        switch selection.state {
        case .preparing(let preparation): selection.cancelPreparation(preparation)
        case .reviewing: selection.cancelReview()
        case .submitting: return
        case .committed: selection.finishCommittedResult()
        case .inactive, .selecting, .failed: break
        }
        guard !duplicate.isSubmitting, !merge.isSubmitting else { return }
        duplicate.cancelActive()
        merge.cancelActive()
        cancelCategoryPicker()
        sheetContent = nil
        commandSheet = nil
    }

    func selectCategory(
        _ categoryID: String?,
        feedContext: TransactionSelectionContext?,
        repository: any TransactionBatchRepositoryProtocol
    ) {
        guard case .categoryPicker(let pickerContext) = sheetContent,
              let feedContext,
              case .selecting(let currentContext, _) = selection.state,
              pickerContext == currentContext,
              pickerContext == feedContext else {
            if case .categoryPicker = sheetContent {
                contextChanged(to: feedContext)
            }
            return
        }
        cancelCategoryPicker()
        prepare(
            intent: .categorize(categoryID: categoryID),
            feedContext: feedContext,
            repository: repository
        )
    }

    @discardableResult
    func prepare(
        intent: TransactionBatchIntent,
        feedContext: TransactionSelectionContext?,
        repository: any TransactionBatchRepositoryProtocol
    ) -> Task<Void, Never>? {
        guard let feedContext,
              case .selecting(let context, _) = selection.state,
              context == feedContext,
              !commandFlowLocksSelection else {
            if case .selecting(let context, _) = selection.state, context != feedContext {
                contextChanged(to: feedContext)
            }
            return nil
        }
        endCommandFlows()
        guard let preparation = selection.beginPreparation(for: intent) else { return nil }
        sheetContent = .review
        return Task { @MainActor [self] in
            do {
                let review = try await repository.reviewTransactionBatch(
                    context: preparation.context,
                    intent: preparation.intent,
                    selections: preparation.selections
                )
                guard isCurrentPreparation(preparation) else { return }
                guard selection.accept(review, for: preparation) else {
                    guard isCurrentPreparation(preparation) else { return }
                    selection.failPreparation(preparation, message: "This selection changed. Review it again before continuing.")
                    sheetContent = nil
                    return
                }
            } catch {
                guard isCurrentPreparation(preparation) else { return }
                selection.failPreparation(preparation, message: error.userFacingMessage ?? error.localizedDescription)
                sheetContent = nil
            }
        }
    }

    func confirm(
        repository: any TransactionBatchRepositoryProtocol,
        currentFeedContext: @escaping @MainActor () -> TransactionSelectionContext?,
        onCommitted: @escaping @MainActor (TransactionBatchOutcome) -> Void
    ) {
        guard let review = selection.beginSubmission() else { return }
        Task { @MainActor [self] in
            do {
                let outcome = try await repository.commitTransactionBatch(
                    review: review,
                    authorization: review.authorization
                )
                selection.completeSubmission(reviewID: review.id, result: outcome)
                onCommitted(outcome)
            } catch {
                selection.failSubmission(reviewID: review.id, message: error.userFacingMessage ?? error.localizedDescription)
                let currentContext = currentFeedContext()
                if currentContext != review.context {
                    contextChanged(to: currentContext)
                } else {
                    sheetContent = nil
                }
            }
        }
    }

    @discardableResult
    func prepareDuplicate(
        feedContext: TransactionSelectionContext?,
        repository: any TransactionDuplicateRepositoryProtocol
    ) -> Task<Void, Never>? {
        guard let selections = commandSelections(matching: feedContext) else { return nil }
        merge.cancelActive()
        guard let preparation = duplicate.beginPreparation(
            context: selections.context,
            selections: selections.identities
        ) else { return nil }
        cancelCategoryPicker()
        sheetContent = nil
        commandSheet = .duplicate
        return Task { @MainActor [self] in
            do {
                let review = try await repository.reviewTransactionDuplicate(
                    context: preparation.context,
                    selections: preparation.selections
                )
                guard duplicate.isCurrent(preparation) else { return }
                guard duplicate.accept(review, for: preparation) else {
                    guard duplicate.isCurrent(preparation) else { return }
                    duplicate.failPreparation(
                        preparation,
                        message: "This selection changed. Review it again before continuing."
                    )
                    commandSheet = nil
                    return
                }
            } catch {
                guard duplicate.isCurrent(preparation) else { return }
                duplicate.failPreparation(
                    preparation,
                    message: error.userFacingMessage ?? error.localizedDescription
                )
                commandSheet = nil
            }
        }
    }

    @discardableResult
    func prepareMerge(
        feedContext: TransactionSelectionContext?,
        repository: any TransactionMergeRepositoryProtocol
    ) -> Task<Void, Never>? {
        guard let selections = commandSelections(matching: feedContext) else { return nil }
        duplicate.cancelActive()
        guard let preparation = merge.beginPreparation(
            context: selections.context,
            selections: selections.identities
        ) else { return nil }
        cancelCategoryPicker()
        sheetContent = nil
        commandSheet = .merge
        return Task { @MainActor [self] in
            do {
                let review = try await repository.reviewTransactionMerge(
                    context: preparation.context,
                    orderedTransactionIDs: preparation.orderedTransactionIDs
                )
                guard merge.isCurrent(preparation) else { return }
                guard merge.accept(review, for: preparation) else {
                    guard merge.isCurrent(preparation) else { return }
                    merge.failPreparation(
                        preparation,
                        message: "This selection changed. Review it again before continuing."
                    )
                    commandSheet = nil
                    return
                }
            } catch {
                guard merge.isCurrent(preparation) else { return }
                merge.failPreparation(
                    preparation,
                    message: error.userFacingMessage ?? error.localizedDescription
                )
                commandSheet = nil
            }
        }
    }

    func confirmDuplicate(
        repository: any TransactionDuplicateRepositoryProtocol,
        currentFeedContext: @escaping @MainActor () -> TransactionSelectionContext?,
        onCommitted: @escaping @MainActor (TransactionDuplicateOutcome) -> Void
    ) {
        guard let review = duplicate.beginSubmission() else { return }
        Task { @MainActor [self] in
            do {
                let outcome = try await repository.commitTransactionDuplicate(review: review)
                duplicate.completeSubmission(reviewID: review.id, result: outcome)
                onCommitted(outcome)
            } catch {
                duplicate.failSubmission(
                    reviewID: review.id,
                    message: error.userFacingMessage ?? error.localizedDescription
                )
                let currentContext = currentFeedContext()
                if currentContext != review.context {
                    contextChanged(to: currentContext)
                } else {
                    commandSheet = nil
                }
            }
        }
    }

    func confirmMerge(
        repository: any TransactionMergeRepositoryProtocol,
        currentFeedContext: @escaping @MainActor () -> TransactionSelectionContext?,
        onCommitted: @escaping @MainActor (TransactionMergeOutcome) -> Void
    ) {
        guard let review = merge.beginSubmission() else { return }
        Task { @MainActor [self] in
            do {
                let outcome = try await repository.commitTransactionMerge(
                    review: review,
                    authorization: TransactionMergeCoordinator.authorization(for: review)
                )
                merge.completeSubmission(reviewID: review.id, result: outcome)
                onCommitted(outcome)
            } catch {
                merge.failSubmission(
                    reviewID: review.id,
                    message: error.userFacingMessage ?? error.localizedDescription
                )
                let currentContext = currentFeedContext()
                if currentContext != review.context {
                    contextChanged(to: currentContext)
                } else {
                    commandSheet = nil
                }
            }
        }
    }

    func finishCommittedResult() {
        if duplicate.isCommitted {
            duplicate.finishCommittedResult()
            commandSheet = nil
            selection.exit()
            return
        }
        if merge.isCommitted {
            merge.finishCommittedResult()
            commandSheet = nil
            selection.exit()
            return
        }
        selection.finishCommittedResult()
        sheetContent = nil
    }

    private var commandFlowLocksSelection: Bool {
        duplicate.hidesSelectionChrome || merge.hidesSelectionChrome
    }

    private var isProtectedFlow: Bool {
        switch selection.state {
        case .submitting, .committed:
            return true
        case .inactive, .selecting, .preparing, .reviewing, .failed:
            return duplicate.isSubmitting || merge.isSubmitting || duplicate.isCommitted || merge.isCommitted
        }
    }

    private var currentSelectionContext: TransactionSelectionContext? {
        switch selection.state {
        case .selecting(let context, _), .failed(let context, _, _): context
        case .preparing(let preparation): preparation.context
        case .reviewing(let review), .submitting(let review): review.context
        case .inactive, .committed: nil
        }
    }

    private func commandSelections(
        matching feedContext: TransactionSelectionContext?
    ) -> (context: TransactionSelectionContext, identities: [TransactionSelectionIdentity])? {
        guard let feedContext,
              case .selecting(let context, let selections) = selection.state,
              context == feedContext,
              !commandFlowLocksSelection else {
            if case .selecting(let context, _) = selection.state, context != feedContext {
                contextChanged(to: feedContext)
            }
            return nil
        }
        return (context, selections.identities)
    }

    private func endCommandFlows() {
        duplicate.invalidate()
        merge.invalidate()
        commandSheet = nil
    }

    private func cancelCategoryPicker() {
        categoryPicker?.cancel()
        categoryPicker = nil
    }

    private func isCurrentPreparation(_ preparation: TransactionSelectionCoordinator.Preparation) -> Bool {
        guard case .preparing(let current) = selection.state else { return false }
        return current.id == preparation.id && current.generation == preparation.generation
    }
}
