import Foundation
import Observation

@MainActor
@Observable
final class BudgetCategoryVisibilityWorkflow {
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    private var generation = 0

    func cancel() {
        generation += 1
        isSubmitting = false
    }

    func setCategoryHidden(
        _ hidden: Bool,
        categoryID: String,
        groupHidden: Bool,
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        if groupHidden {
            errorMessage = "Show the group before changing a category."
            return nil
        }
        return await submit(
            selectedMonth: selectedMonth,
            budgetID: budgetID
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
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        if group.isIncome {
            errorMessage = "Income groups cannot be hidden."
            return nil
        }
        return await submit(
            selectedMonth: selectedMonth,
            budgetID: budgetID
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
        work: (String, String) async throws -> LoadedBudgetMonth
    ) async -> LoadedBudgetMonth? {
        guard !isSubmitting else {
            return nil
        }
        guard let selectedMonth, let budgetID else {
            errorMessage = "No budget is open."
            return nil
        }

        generation += 1
        let token = generation
        isSubmitting = true
        errorMessage = nil

        do {
            let loaded = try await work(selectedMonth, budgetID)
            guard token == generation else {
                return nil
            }
            isSubmitting = false
            return loaded
        } catch {
            guard token == generation else {
                return nil
            }
            isSubmitting = false
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
