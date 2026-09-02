import Foundation
import Observation

/// Screen state for the History sheet: loading, the LIFO undo flow, and errors.
/// Undo runs preview (on tap) and commit (on confirm), both through the
/// repository — the commit re-checks the conflict decision, so a stale review
/// refuses instead of clobbering newer values.
@MainActor
@Observable
final class HistoryViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// One value owns the whole undo flow; no parallel bools. The review
    /// presentation stays attached while committing so the sheet can show
    /// progress in place.
    enum UndoState: Equatable {
        case idle
        case preparing(actionID: String)
        case reviewing(HistoryUndoReviewPresentation)
        case committing(HistoryUndoReviewPresentation)
        case failed(actionID: String, message: String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var rows: [HistoryRowModel] = []
    private(set) var undoState: UndoState = .idle

    private var records: [BudgetActionRecord] = []
    private var categoryNames: [String: String] = [:]
    private var currency: BudgetCurrency = .usd
    private var privacyEnabled = false
    private var preparationGeneration = 0

    var isPreparingUndoForRowID: String? {
        if case .preparing(let actionID) = undoState {
            return actionID
        }
        return nil
    }

    var committingActionID: String? {
        if case .committing(let presentation) = undoState {
            return presentation.actionID
        }
        return nil
    }

    /// The review sheet's identity, or nil when no review is presented.
    var activeReview: HistoryUndoReviewPresentation? {
        switch undoState {
        case .reviewing(let presentation), .committing(let presentation):
            return presentation
        case .idle, .preparing, .failed:
            return nil
        }
    }

    var undoFailureMessage: String? {
        if case .failed(_, let message) = undoState {
            return message
        }
        return nil
    }

    func load(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            loadState = .failed("Open a budget to see its history.")
            return
        }
        privacyEnabled = appState.settings.randomizedDisplayValuesEnabled
        currency = appState.localFirstStore.budgetCurrency(budgetID: budgetID)
        await load(budgetID: budgetID, repository: appState.budgetRepository)
    }

    func refresh(using appState: AppState) async {
        await load(using: appState)
    }

    private func load(
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async {
        if rows.isEmpty {
            loadState = .loading
        }
        do {
            async let fetchedRecords = repository.recentBudgetActions(budgetID: budgetID)
            async let fetchedNames = repository.budgetActionCategoryNames(budgetID: budgetID)
            records = try await fetchedRecords
            categoryNames = try await fetchedNames
            rebuildRows()
            loadState = .loaded
        } catch {
            loadState = .failed(Self.loadFailureMessage(for: error))
        }
    }

    /// LIFO policy (Q2): the newest applied row is the only row offering Undo.
    /// After that row is undone, the previous applied row becomes undoable.
    private func rebuildRows() {
        let undoableActionID = records.first { $0.status == .applied }?.id
        rows = HistoryRowPresentation.rows(
            from: records,
            categoryNames: categoryNames,
            undoableActionID: undoableActionID,
            currency: currency,
            privacyEnabled: privacyEnabled
        )
    }

    /// Undo tap: fetch the live preview and present the review. A generation
    /// counter drops a stale prepare that finishes after the user cancelled.
    func beginUndo(_ row: HistoryRowModel, using appState: AppState) async {
        guard row.canUndo, undoState == .idle,
              let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        preparationGeneration += 1
        let generation = preparationGeneration
        undoState = .preparing(actionID: row.id)
        do {
            let preview = try await appState.budgetRepository.budgetActionUndoPreview(
                actionID: row.id,
                budgetID: budgetID
            )
            guard generation == preparationGeneration, undoState == .preparing(actionID: row.id) else {
                return
            }
            undoState = .reviewing(reviewPresentation(from: preview, row: row))
        } catch {
            guard generation == preparationGeneration else {
                return
            }
            undoState = .failed(actionID: row.id, message: Self.undoFailureMessage(for: error))
        }
    }

    func cancelUndo() {
        switch undoState {
        case .preparing, .reviewing:
            preparationGeneration += 1
            undoState = .idle
        case .idle, .committing, .failed:
            break
        }
    }

    /// Confirm: commit the undo, then reload rows so the undone marker and the
    /// new "newest applied" row reflect storage. Budget and other tabs refresh
    /// through `localDataRevision` (the store bumps it on every mutation).
    func confirmUndo(using appState: AppState) async {
        guard case .reviewing(let presentation) = undoState,
              let budgetID = appState.settings.selectedBudgetID else {
            return
        }
        undoState = .committing(presentation)
        do {
            try await appState.budgetRepository.undoBudgetActionAndRefresh(
                actionID: presentation.actionID,
                budgetID: budgetID
            )
            undoState = .idle
            await load(budgetID: budgetID, repository: appState.budgetRepository)
        } catch {
            undoState = .failed(
                actionID: presentation.actionID,
                message: Self.undoFailureMessage(for: error)
            )
        }
    }

    func dismissUndoFailure() {
        if case .failed = undoState {
            undoState = .idle
        }
    }

    private func reviewPresentation(
        from preview: BudgetActionUndoPreview,
        row: HistoryRowModel
    ) -> HistoryUndoReviewPresentation {
        var entries = preview.entries.map { entry in
            HistoryUndoReviewPresentation.Entry(
                categoryID: entry.categoryID,
                name: HistoryRowPresentation.displayName(
                    for: entry.categoryID,
                    categoryNames: categoryNames,
                    privacyEnabled: privacyEnabled
                ),
                currentText: HistoryRowPresentation.moneyText(
                    entry.current,
                    seed: "\(preview.actionID)-current-\(entry.categoryID)",
                    currency: currency,
                    privacyEnabled: privacyEnabled
                ),
                proposedText: HistoryRowPresentation.moneyText(
                    entry.proposed,
                    seed: "\(preview.actionID)-proposed-\(entry.categoryID)",
                    currency: currency,
                    privacyEnabled: privacyEnabled
                )
            )
        }
        if entries.isEmpty {
            entries = preview.transactionLines.map { line in
                let name = HistoryRowPresentation.displayPayee(
                    line.payeeName,
                    seed: line.id,
                    privacyEnabled: privacyEnabled
                ) ?? "Transaction"
                let current: String
                let proposed: String
                switch line.effect {
                case .delete:
                    current = line.amount.map {
                        HistoryRowPresentation.moneyText(
                            $0,
                            seed: "\(preview.actionID)-txn-\(line.id)",
                            currency: currency,
                            privacyEnabled: privacyEnabled
                        )
                    } ?? "Transaction"
                    proposed = "Deleted"
                case .restore:
                    current = "Deleted"
                    proposed = line.amount.map {
                        HistoryRowPresentation.moneyText(
                            $0,
                            seed: "\(preview.actionID)-txn-\(line.id)",
                            currency: currency,
                            privacyEnabled: privacyEnabled
                        )
                    } ?? "Restored"
                case .recategorize:
                    current = HistoryRowPresentation.displayName(
                        for: line.currentCategoryID,
                        categoryNames: categoryNames,
                        privacyEnabled: privacyEnabled
                    )
                    proposed = HistoryRowPresentation.displayName(
                        for: line.proposedCategoryID,
                        categoryNames: categoryNames,
                        privacyEnabled: privacyEnabled
                    )
                case .edit:
                    current = line.amount.map {
                        HistoryRowPresentation.moneyText(
                            $0,
                            seed: "\(preview.actionID)-txn-\(line.id)",
                            currency: currency,
                            privacyEnabled: privacyEnabled
                        )
                    } ?? "Current"
                    proposed = "Previous"
                }
                return HistoryUndoReviewPresentation.Entry(
                    categoryID: line.id,
                    name: name,
                    currentText: current,
                    proposedText: proposed
                )
            }
        }
        let summary = records.first { $0.id == preview.actionID }.map {
            HistoryRowPresentation.gestureSummary(
                for: $0,
                categoryNames: categoryNames,
                currency: currency,
                privacyEnabled: privacyEnabled
            )
        } ?? row.title
        return HistoryUndoReviewPresentation(
            actionID: preview.actionID,
            gestureSummary: summary,
            entries: entries,
            blockReason: preview.block?.userFacingReason
        )
    }

    private static func loadFailureMessage(for error: any Error) -> String {
        if let error = error as? LocalFirstError, let description = error.errorDescription {
            return description
        }
        return "History could not load. Pull to retry."
    }

    private static func undoFailureMessage(for error: any Error) -> String {
        if let error = error as? LocalFirstError, let description = error.errorDescription {
            return description
        }
        return "The undo could not be applied. Nothing was changed."
    }
}
