import Foundation
import Observation

/// Which budget a layout shows and which one the app has selected. A category
/// action runs only while both name the same budget, and its result is used only
/// if they still do when the write returns.
struct BudgetActionBudgetScope {
    let visible: @MainActor () -> String?
    let selected: @MainActor () -> String?

    /// The budget id when the visible budget is the selected one, else nil.
    @MainActor func currentID() -> String? {
        guard let id = visible(), id == selected() else { return nil }
        return id
    }
}

@MainActor
@Observable
final class BudgetCategoryFlagWorkflow {
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
        currentBudgetID: @MainActor () -> String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        if groupHidden {
            errorMessage = "Show the group first to change this category."
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
        currentBudgetID: @MainActor () -> String?,
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

    /// Rollover applies from `selectedMonth` onward, as on the category details screen.
    func setCategoryCarryover(
        _ carryover: Bool,
        category: BudgetMonthCategory,
        expectedMode: BudgetModeIdentity?,
        selectedMonth: String?,
        budgetID: String?,
        currentBudgetID: @MainActor () -> String?,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        if category.isIncome {
            errorMessage = "Rollover is only available for expense categories."
            return nil
        }
        return await submit(
            selectedMonth: selectedMonth,
            budgetID: budgetID,
            currentBudgetID: currentBudgetID
        ) { month, budgetID in
            try await repository.setCategoryCarryoverAndRefresh(
                expectedMode: expectedMode,
                categoryID: category.id,
                carryover: carryover,
                budgetID: budgetID,
                startMonth: month
            ) {}
        }
    }

    /// Hide or show a category, then run the layout's `refresh`. Both layouts share
    /// the guards: nothing is written unless the visible budget is the selected
    /// one, and nothing is refreshed (or reported) if that changed during the write.
    func commitCategoryHidden(
        _ hidden: Bool,
        categoryID: String,
        groupHidden: Bool,
        month: String?,
        budget: BudgetActionBudgetScope,
        repository: any BudgetRepositoryProtocol,
        refresh: @MainActor () async -> Void
    ) async {
        guard let budgetID = budget.currentID() else { return }
        guard await setCategoryHidden(
            hidden,
            categoryID: categoryID,
            groupHidden: groupHidden,
            selectedMonth: month,
            budgetID: budgetID,
            currentBudgetID: budget.currentID,
            repository: repository
        ) != nil else { return }
        await refresh()
    }

    func commitGroupHidden(
        _ hidden: Bool,
        group: BudgetMonthCategoryGroup,
        month: String?,
        budget: BudgetActionBudgetScope,
        repository: any BudgetRepositoryProtocol,
        refresh: @MainActor () async -> Void
    ) async {
        guard let budgetID = budget.currentID() else { return }
        guard await setGroupHidden(
            hidden,
            group: group,
            selectedMonth: month,
            budgetID: budgetID,
            currentBudgetID: budget.currentID,
            repository: repository
        ) != nil else { return }
        await refresh()
    }

    /// `expectedMode` comes from the layout's own loaded data.
    func commitCategoryCarryover(
        _ carryover: Bool,
        category: BudgetMonthCategory,
        expectedMode: BudgetModeIdentity?,
        month: String?,
        budget: BudgetActionBudgetScope,
        repository: any BudgetRepositoryProtocol,
        refresh: @MainActor () async -> Void
    ) async {
        guard let budgetID = budget.currentID() else { return }
        guard await setCategoryCarryover(
            carryover,
            category: category,
            expectedMode: expectedMode,
            selectedMonth: month,
            budgetID: budgetID,
            currentBudgetID: budget.currentID,
            repository: repository
        ) != nil else { return }
        await refresh()
    }

    private func submit(
        selectedMonth: String?,
        budgetID: String?,
        currentBudgetID: @MainActor () -> String?,
        work: (String, String) async throws -> LoadedBudgetMonth
    ) async -> LoadedBudgetMonth? {
        guard !isSubmitting else {
            return nil
        }
        guard let selectedMonth, let budgetID else {
            errorMessage = "Open a budget first."
            return nil
        }

        isSubmitting = true
        errorMessage = nil

        do {
            let loaded = try await work(selectedMonth, budgetID)
            isSubmitting = false
            // The write committed to the budget captured above; if another budget
            // is selected now, the caller must not refresh or apply for it.
            if currentBudgetID() != budgetID { return nil }
            return loaded
        } catch {
            isSubmitting = false
            if currentBudgetID() != budgetID { return nil }
            errorMessage = error.userFacingMessage
            return nil
        }
    }
}
