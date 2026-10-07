import Foundation
import Observation

@MainActor
@Observable
final class BudgetCategoryVisibilityWorkflow {
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    /// A committed write cannot be cancelled; teardown while submitting is refused
    /// so the result still reaches the caller and a second write is rejected.
    func cancel() {
        guard !isSubmitting else { return }
        errorMessage = nil
    }

    func setCategoryHidden(
        _ hidden: Bool,
        categoryID: String,
        groupHidden: Bool,
        selectedMonth: String?,
        budgetID: String?,
        currentBudgetID: (@MainActor () -> String?)? = nil,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        if groupHidden {
            errorMessage = "Show the group before changing a category."
            return nil
        }
        return await submit(
            selectedMonth: selectedMonth,
            budgetID: budgetID,
            currentBudgetID: currentBudgetID
        ) { month, budgetID in
            try await repository.setCategoryHiddenAndRefresh(
                categoryID: categoryID,
                hidden: hidden,
                budgetID: budgetID,
                month: month
            ) {}
        }
    }

    func setGroupHidden(
        _ hidden: Bool,
        group: BudgetMonthCategoryGroup,
        selectedMonth: String?,
        budgetID: String?,
        currentBudgetID: (@MainActor () -> String?)? = nil,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        if group.isIncome {
            errorMessage = "Income groups cannot be hidden."
            return nil
        }
        return await submit(
            selectedMonth: selectedMonth,
            budgetID: budgetID,
            currentBudgetID: currentBudgetID
        ) { month, budgetID in
            try await repository.setCategoryGroupHiddenAndRefresh(
                groupID: group.id,
                hidden: hidden,
                budgetID: budgetID,
                month: month
            ) {}
        }
    }

    private func submit(
        selectedMonth: String?,
        budgetID: String?,
        currentBudgetID: (@MainActor () -> String?)?,
        work: (String, String) async throws -> LoadedBudgetMonth
    ) async -> LoadedBudgetMonth? {
        guard !isSubmitting else {
            return nil
        }
        guard let selectedMonth, let budgetID else {
            errorMessage = "No budget is open."
            return nil
        }

        isSubmitting = true
        errorMessage = nil

        do {
            let loaded = try await work(selectedMonth, budgetID)
            isSubmitting = false
            // The write committed to the budget captured above; if another budget
            // is selected now, the caller must not refresh or apply for it.
            if let currentBudgetID, currentBudgetID() != budgetID { return nil }
            return loaded
        } catch {
            isSubmitting = false
            if let currentBudgetID, currentBudgetID() != budgetID { return nil }
            errorMessage = error.userFacingMessage
            return nil
        }
    }
}
