import Foundation
import Observation

@MainActor
@Observable
final class BudgetViewModel {
    var budgetMonth: BudgetMonth?
    var selectedMonth: String?
    var availableMonths: [String] = []
    var expandedGroupIDs: Set<String> = []
    var isLoading = false
    var errorMessage: String?

    var navigationTitle: String {
        guard let selectedMonth else {
            return Self.title(for: Date())
        }

        return Self.title(forMonthIdentifier: selectedMonth)
    }

    var visibleGroups: [BudgetMonthCategoryGroup] {
        budgetMonth?.categoryGroups.filter { !$0.isIncome } ?? []
    }

    var overspendingAlertCount: Int? {
        guard let budgetMonth else {
            return nil
        }

        let overspentCategoryCount = visibleGroups
            .flatMap(\.visibleCategories)
            .filter { $0.balance < 0 }
            .count

        if overspentCategoryCount > 0 {
            return overspentCategoryCount
        }

        return budgetMonth.lastMonthOverspent < 0 ? 1 : nil
    }

    var preferredMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    func load(using appState: AppState) async {
        await appState.loadBudgets()

        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return
        }

        await load(budgetID: budgetID, repository: repository)
    }

    func load(
        budgetID: String,
        repository: BudgetRepository
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            let loadedMonth = try await repository.currentBudgetMonth(
                budgetID: budgetID,
                preferredMonth: preferredMonth
            )
            availableMonths = loadedMonth.availableMonths
            budgetMonth = loadedMonth.month
            selectedMonth = loadedMonth.month.month
            expandedGroupIDs = Set(loadedMonth.month.categoryGroups.prefix(3).map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func isExpanded(_ group: BudgetMonthCategoryGroup) -> Bool {
        expandedGroupIDs.contains(group.id)
    }

    func toggle(_ group: BudgetMonthCategoryGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }

    private static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private static func title(forMonthIdentifier month: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM"
        guard let date = input.date(from: month) else {
            return month
        }

        return title(for: date)
    }
}

extension BudgetMonthCategoryGroup {
    var visibleCategories: [BudgetMonthCategory] {
        categories.filter { !($0.hidden ?? false) }
    }
}
