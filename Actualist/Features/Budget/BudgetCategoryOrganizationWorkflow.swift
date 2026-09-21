import Foundation
import Observation

@MainActor
@Observable
final class BudgetCategoryOrganizationWorkflow {
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    private var generation = 0

    func cancel() {
        generation += 1
        isSubmitting = false
    }

    func createCategory(
        name: String,
        group: BudgetMonthCategoryGroup,
        isTrackingBudget: Bool,
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard isTrackingBudget || !group.isIncome else {
            errorMessage = "Income categories cannot be managed in an envelope budget."
            return nil
        }
        guard let name = validatedName(name, kind: "Category") else { return nil }
        return await submit(selectedMonth: selectedMonth, budgetID: budgetID) { month, budgetID in
            try await repository.createCategoryAndRefresh(
                name: name, groupID: group.id, budgetID: budgetID, month: month
            )
        }
    }

    func createGroup(
        name: String,
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard let name = validatedName(name, kind: "Category group") else { return nil }
        return await submit(selectedMonth: selectedMonth, budgetID: budgetID) { month, budgetID in
            try await repository.createCategoryGroupAndRefresh(name: name, budgetID: budgetID, month: month)
        }
    }

    func renameCategory(
        _ category: BudgetMonthCategory,
        name: String,
        isTrackingBudget: Bool,
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard isTrackingBudget || !category.isIncome else {
            errorMessage = "Income categories cannot be managed in an envelope budget."
            return nil
        }
        guard let name = validatedName(name, kind: "Category"), name != category.name else { return nil }
        return await submit(selectedMonth: selectedMonth, budgetID: budgetID) { month, budgetID in
            try await repository.renameCategoryAndRefresh(
                categoryID: category.id, name: name, budgetID: budgetID, month: month
            )
        }
    }

    func renameGroup(
        _ group: BudgetMonthCategoryGroup,
        name: String,
        isTrackingBudget: Bool,
        selectedMonth: String?,
        budgetID: String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard isTrackingBudget || !group.isIncome else {
            errorMessage = "Income groups cannot be managed in an envelope budget."
            return nil
        }
        guard let name = validatedName(name, kind: "Category group"), name != group.name else { return nil }
        return await submit(selectedMonth: selectedMonth, budgetID: budgetID) { month, budgetID in
            try await repository.renameCategoryGroupAndRefresh(
                groupID: group.id, name: name, budgetID: budgetID, month: month
            )
        }
    }

    private func validatedName(_ name: String, kind: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "\(kind) name cannot be empty."
            return nil
        }
        return trimmed
    }

    private func submit(
        selectedMonth: String?,
        budgetID: String?,
        work: (String, String) async throws -> LoadedBudgetMonth
    ) async -> LoadedBudgetMonth? {
        guard !isSubmitting else { return nil }
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
            guard token == generation else { return nil }
            isSubmitting = false
            return loaded
        } catch {
            guard token == generation else { return nil }
            isSubmitting = false
            errorMessage = error.userFacingMessage
            return nil
        }
    }
}
