import Observation

@MainActor
@Observable
final class BudgetTemplateWorkflow {
    private(set) var submissionState: BudgetAssignmentSubmissionState = .draft

    /// Monotonically increasing token bumped whenever the displayed month/budget
    /// selection changes (`noteSelectionChange`, called by the view model on
    /// any `apply`) so a stale async template refresh that returns after the
    /// user navigated can be detected. The view model owns the current
    /// selection; this counter only tracks *whether* it changed.
    private var selectionGeneration = 0

    var isApplying: Bool {
        submissionState.isSubmitting
    }

    /// Identity of an in-flight Apply Templates request, captured before the
    /// async repository call and re-checked when it returns. Only a result that
    /// still matches the view model's current context is applied to the UI.
    struct Request: Equatable {
        let budgetID: String
        let month: String
        let generation: Int
    }

    /// Called by the view model whenever the displayed month/budget selection
    /// changes (its single `apply` choke point). Bumps the generation so any
    /// in-flight template request is superseded by the new selection.
    func noteSelectionChange() {
        selectionGeneration += 1
    }

    /// Capture the request identity before the async repository call. The
    /// repository write targets this captured month regardless of later
    /// navigation; `isCurrent` later decides whether the returned refresh may
    /// replace the current UI.
    func beginRequest(budgetID: String, month: String) -> Request {
        Request(budgetID: budgetID, month: month, generation: selectionGeneration)
    }

    /// True when the view model is still on the same budget + month and no
    /// selection change or newer request has superseded `request`. The view
    /// model supplies its current `budgetID`/`month` (it owns the selection);
    /// `currentBudgetID == nil` mirrors `apply`'s rule that an unestablished
    /// budget matches any request on the budget axis.
    func isCurrent(
        _ request: Request,
        currentBudgetID: String?,
        currentMonth: String?
    ) -> Bool {
        let isSameBudget = currentBudgetID == nil || currentBudgetID == request.budgetID
        return isSameBudget
            && currentMonth == request.month
            && selectionGeneration == request.generation
    }

    func apply(
        command: BudgetTemplateCommand,
        selectedMonth: String,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Result<LoadedBudgetMonth, Error> {
        guard !submissionState.isSubmitting else {
            return .failure(BudgetTemplateWorkflowError.alreadyApplying)
        }

        submissionState = .submitting

        do {
            let loadedMonth = try await repository.applyBudgetTemplateAndRefresh(
                command: command,
                budgetID: budgetID,
                month: selectedMonth
            ) { [weak self] in
                await MainActor.run {
                    self?.submissionState = .refetching
                }
            }
            submissionState = .draft
            return .success(loadedMonth)
        } catch {
            submissionState = .failed(error.localizedDescription)
            return .failure(error)
        }
    }

    /// Drop a result that is stale relative to the view model's current
    /// month/budget context (the user navigated while the async apply was in
    /// flight, or a newer request superseded it). The write already targeted
    /// the captured month and synced normally; only the returned refresh is
    /// discarded. Reset the submission display state so a stale failure does
    /// not linger on the apply button for the current context. A newer
    /// in-flight request owns `.submitting`/`.refetching` and is left alone.
    func discardStaleResult() {
        if case .failed = submissionState {
            submissionState = .draft
        }
    }
}

private enum BudgetTemplateWorkflowError: Error {
    case alreadyApplying
}
