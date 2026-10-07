import Observation

@MainActor
@Observable
final class BudgetCategoryReorderWorkflow {
    private(set) var draft: BudgetCategoryOutlineDraft?
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    func begin(groups: [BudgetMonthCategoryGroup], isTrackingBudget: Bool) {
        guard !isSubmitting else { return }
        errorMessage = nil
        draft = BudgetCategoryOutlineDraft(groups: groups, isTrackingBudget: isTrackingBudget)
    }

    /// A committed write cannot be cancelled; teardown while submitting is refused
    /// so the result still reaches the caller and a second save is rejected.
    func cancel() {
        guard !isSubmitting else { return }
        errorMessage = nil
        draft = nil
    }

    func moveCategory(id: String, toGroupID: String, beforeCategoryID: String?) {
        do {
            try draft?.moveCategory(id: id, toGroupID: toGroupID, beforeCategoryID: beforeCategoryID)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func moveGroup(id: String, beforeGroupID: String?) {
        do {
            try draft?.moveGroup(id: id, beforeGroupID: beforeGroupID)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func save(
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard !isSubmitting, let command = draft?.command else { return nil }
        guard let selectedMonth, let budgetID else {
            errorMessage = "No budget is open."
            return nil
        }
        isSubmitting = true
        errorMessage = nil
        do {
            let loaded = try await repository.applyCategoryOutlineAndRefresh(
                draft: command, budgetID: budgetID, month: selectedMonth
            )
            isSubmitting = false
            draft = nil
            return loaded
        } catch {
            isSubmitting = false
            errorMessage = error.userFacingMessage
            return nil
        }
    }
}
