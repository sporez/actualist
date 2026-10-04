import Foundation

extension BudgetMoveMoneyDraft {
    var commands: [BudgetMoveMoneyCommand] {
        if !allocations.isEmpty {
            return allocations
                .filter { $0.amount > 0 }
                .map { allocation in
                    command(
                        destination: allocation.destination,
                        amount: allocation.amount
                    )
                }
        }

        guard let destination, amount > 0 else {
            return []
        }

        return [command(destination: destination, amount: amount)]
    }

    private func command(
        destination: BudgetMoveMoneyDestination,
        amount: Int
    ) -> BudgetMoveMoneyCommand {
        switch direction {
        case .outOfFocusedCategory:
            BudgetMoveMoneyCommand(
                fromCategoryID: focusedCategoryID,
                toCategoryID: destination.categoryID,
                amount: amount
            )
        case .intoFocusedCategory:
            BudgetMoveMoneyCommand(
                fromCategoryID: destination.categoryID,
                toCategoryID: focusedCategoryID,
                amount: amount
            )
        }
    }

    func scaleBaseline(
        for allocationID: String?,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        switch direction {
        case .outOfFocusedCategory:
            return max(
                0,
                payingAvailable(
                    for: allocationID,
                    budgetMonth: budgetMonth,
                    visibleGroups: visibleGroups
                )
            )
        case .intoFocusedCategory:
            let paying = payingAvailable(
                for: allocationID,
                budgetMonth: budgetMonth,
                visibleGroups: visibleGroups
            )
            if paying == 0,
               destination == nil,
               allocations.isEmpty {
                return Int(clamping: min(0, focusedAvailable).magnitude)
            }
            return max(0, paying)
        }
    }

    func payingAvailable(
        for allocationID: String?,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        switch direction {
        case .outOfFocusedCategory:
            let others: Int
            if let allocationID, !allocations.isEmpty {
                others = allocations
                    .filter { $0.id != allocationID }
                    .reduce(0) { $0.addingClamped($1.amount) }
            } else {
                others = 0
            }
            return focusedAvailable.subtractingClamped(others)
        case .intoFocusedCategory:
            let destination: BudgetMoveMoneyDestination?
            if let allocationID {
                destination = allocations.first(where: { $0.id == allocationID })?.destination
            } else {
                destination = self.destination
            }
            guard let destination else {
                return 0
            }
            return Self.availableAmount(
                for: destination,
                budgetMonth: budgetMonth,
                visibleGroups: visibleGroups
            )
        }
    }

    static func availableAmount(
        for destination: BudgetMoveMoneyDestination?,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        switch destination {
        case .toBudget:
            budgetMonth?.toBudget ?? 0
        case .category(let id, _):
            visibleGroups
                .flatMap(\.visibleCategories)
                .first { $0.id == id }?
                .balance ?? 0
        case nil:
            0
        }
    }
}

extension Int {
    func addingClamped(_ other: Int) -> Int {
        let result = addingReportingOverflow(other)
        guard result.overflow else { return result.partialValue }
        return other >= 0 ? Int.max : Int.min
    }

    func subtractingClamped(_ other: Int) -> Int {
        let result = subtractingReportingOverflow(other)
        guard result.overflow else { return result.partialValue }
        return other >= 0 ? Int.min : Int.max
    }
}
