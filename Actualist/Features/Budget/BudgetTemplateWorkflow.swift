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
        let modeIdentity: BudgetModeIdentity?
        let generation: Int
    }

    /// Called by the view model whenever the displayed month/budget selection
    /// changes (its single `apply` choke point). Bumps the generation so any
    /// in-flight template request is superseded by the new selection.
    func noteSelectionChange() {
        selectionGeneration += 1
        submissionState = .draft
    }

    /// Capture the request identity before the async repository call. The
    /// repository write targets this captured month regardless of later
    /// navigation; `isCurrent` later decides whether the returned refresh may
    /// replace the current UI.
    func beginRequest(
        budgetID: String,
        month: String,
        modeIdentity: BudgetModeIdentity? = nil
    ) -> Request {
        Request(
            budgetID: budgetID,
            month: month,
            modeIdentity: modeIdentity,
            generation: selectionGeneration
        )
    }

    /// True when the view model is still on the same budget + month and no
    /// selection change or newer request has superseded `request`. The view
    /// model supplies its current `budgetID`/`month` (it owns the selection);
    /// `currentBudgetID == nil` mirrors `apply`'s rule that an unestablished
    /// budget matches any request on the budget axis.
    func isCurrent(
        _ request: Request,
        currentBudgetID: String?,
        currentMonth: String?,
        currentModeIdentity: BudgetModeIdentity? = nil
    ) -> Bool {
        let isSameBudget = currentBudgetID == nil || currentBudgetID == request.budgetID
        return isSameBudget
            && currentMonth == request.month
            && currentModeIdentity == request.modeIdentity
            && selectionGeneration == request.generation
    }

    func apply(
        command: BudgetTemplateCommand,
        selectedMonth: String,
        budgetID: String,
        expectedMode: BudgetModeIdentity? = nil,
        reviewRevision: BudgetTemplateReviewRevision? = nil,
        repository: any BudgetRepositoryProtocol
    ) async -> Result<LoadedBudgetMonth, Error> {
        guard !submissionState.isSubmitting else {
            return .failure(BudgetTemplateWorkflowError.alreadyApplying)
        }

        let generation = selectionGeneration
        submissionState = .submitting

        do {
            let didApply: @MainActor @Sendable () async -> Void = { [weak self] in
                await MainActor.run {
                    guard self?.selectionGeneration == generation else { return }
                    self?.submissionState = .refetching
                }
            }
            let loadedMonth: LoadedBudgetMonth
            if let reviewRevision {
                loadedMonth = try await repository.applyReviewedBudgetTemplateAndRefresh(
                    reviewRevision: reviewRevision,
                    command: command,
                    budgetID: budgetID,
                    month: selectedMonth,
                    didApply: didApply
                )
            } else {
                loadedMonth = try await repository.applyBudgetTemplateAndRefresh(
                    expectedMode: expectedMode,
                    command: command,
                    budgetID: budgetID,
                    month: selectedMonth,
                    didApply: didApply
                )
            }
            if selectionGeneration == generation { submissionState = .draft }
            return .success(loadedMonth)
        } catch {
            if selectionGeneration == generation { submissionState = error.userFacingMessage.map(BudgetAssignmentSubmissionState.failed) ?? .draft }
            return .failure(error)
        }
    }

    /// Routes a reviewed sheet action through the workflow that owns its
    /// submission state; the view only supplies the selected intent and context.
    static func applyReviewed(
        _ confirmation: BudgetTemplateConfirmation,
        revision: BudgetTemplateReviewRevision,
        model: BudgetViewModel,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> Bool {
        guard model.loadedBudgetID == budgetID,
              model.selectedMonth == revision.month,
              model.modeIdentity == revision.modeIdentity else {
            return false
        }
        switch confirmation {
        case .monthFillEmpty:
            return await model.applyMonthTemplate(
                .fillEmpty, budgetID: budgetID, expectedMode: revision.modeIdentity,
                reviewRevision: revision, repository: repository
            )
        case .monthOverwrite:
            return await model.applyMonthTemplate(
                .overwrite, budgetID: budgetID, expectedMode: revision.modeIdentity,
                reviewRevision: revision, repository: repository
            )
        case .category:
            return await model.applyCategoryTemplate(
                budgetID: budgetID, expectedMode: revision.modeIdentity,
                reviewRevision: revision, repository: repository
            )
        }
    }
}

private enum BudgetTemplateWorkflowError: Error {
    case alreadyApplying
}
