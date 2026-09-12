import Foundation
import Observation

/// Owns the gesture's single month request, never a second copy of budget data.
@MainActor @Observable
final class BudgetMonthSwipeNavigation {
    private(set) var requestID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    static func isAvailable(model: BudgetViewModel, budgetID: String?) -> Bool {
        budgetID != nil && model.loadedBudgetID == budgetID && model.selectedMonth != nil
            && !model.isLoading && !model.isAssignmentKeypadPresented
            && !model.isSubmittingAssignment && !model.isMoveMoneyPresented
            && !model.isSubmittingMoveMoney && !model.isApplyingMonthTemplate
            && !model.isCoveringOverspentSelection
    }

    @discardableResult
    func navigate(_ direction: BudgetMonthSwipePolicy.Direction, model: BudgetViewModel,
                  budgetID: String?, repository: any BudgetRepositoryProtocol) -> Task<Void, Never>? {
        guard requestID == nil, Self.isAvailable(model: model, budgetID: budgetID),
              let budgetID, let month = model.selectedMonth else { return nil }
        let target = BudgetViewportModel.monthID(month, offsetBy: direction.monthOffset)
        guard target != month, target >= "1900-01", target <= "9999-12" else { return nil }
        let collapsed = Set(model.visibleGroups.map(\.id)).subtracting(model.expandedGroupIDs)
        let id = UUID()
        requestID = id
        let next = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == id { self.requestID = nil; self.task = nil }
            }
            guard !Task.isCancelled, Self.isAvailable(model: model, budgetID: budgetID),
                  model.selectedMonth == month else { return }
            await model.selectMonth(target, budgetID: budgetID, repository: repository)
            guard !Task.isCancelled, self.requestID == id,
                  model.loadedBudgetID == budgetID, model.selectedMonth == target else { return }
            model.expandedGroupIDs.subtract(collapsed)
        }
        task = next
        return next
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = nil
    }
}
