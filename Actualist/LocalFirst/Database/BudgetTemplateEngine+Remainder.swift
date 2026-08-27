import Foundation

extension BudgetTemplateEngine {
    func distributeRemainder(
        categories: [String: Category],
        limitStates: [String: LimitState],
        budgetedByCategory: inout [String: Int],
        limitMetByCategory: inout [String: Bool],
        remainingAvailable: inout Int
    ) throws {
        func remainderCategoryIDs() -> [String] {
            categories.keys.sorted().filter { categoryID in
                remainderWeight(of: categories[categoryID]!) > 0
                    && limitMetByCategory[categoryID] != true
            }
        }

        var active = remainderCategoryIDs()
        while remainingAvailable > 0, !active.isEmpty {
            let totalWeight = active.reduce(0.0) { partial, categoryID in
                partial + remainderWeight(of: categories[categoryID]!)
            }
            guard totalWeight > 0 else {
                break
            }
            let perWeight = Double(remainingAvailable) / totalWeight
            let beforePass = remainingAvailable
            for categoryID in active {
                guard let category = categories[categoryID] else {
                    continue
                }
                let allocated = try runRemainder(
                    category: category,
                    limitState: limitStates[categoryID],
                    alreadyBudgeted: budgetedByCategory[categoryID, default: 0],
                    budgetAvailable: remainingAvailable,
                    perWeight: perWeight
                )
                if let limitState = limitStates[categoryID] {
                    let nextBudgeted = try Self.checkedAdd(
                        budgetedByCategory[categoryID, default: 0],
                        allocated
                    )
                    if nextBudgeted + limitState.fromLastMonth >= limitState.limitAmount {
                        limitMetByCategory[categoryID] = true
                    }
                }
                budgetedByCategory[categoryID] = try Self.checkedAdd(
                    budgetedByCategory[categoryID, default: 0],
                    allocated
                )
                remainingAvailable = try Self.checkedSubtract(remainingAvailable, allocated)
            }
            if remainingAvailable == beforePass {
                break
            }
            active = remainderCategoryIDs()
        }
    }

    private func runRemainder(
        category: Category,
        limitState: LimitState?,
        alreadyBudgeted: Int,
        budgetAvailable: Int,
        perWeight: Double
    ) throws -> Int {
        let weight = remainderWeight(of: category)
        guard weight > 0 else {
            return 0
        }

        var toBudget = try Self.actualRound(weight * perWeight)
        let smallest: Int
        if currency.hideFraction {
            toBudget = currency.removingFraction(fromMinorUnits: toBudget)
            smallest = remainderSmallestUnit
        } else {
            smallest = 1
        }

        if toBudget > budgetAvailable {
            toBudget = budgetAvailable
        } else if try Self.checkedSubtract(budgetAvailable, toBudget) <= smallest {
            toBudget = budgetAvailable
        }

        if let limitState {
            let room = try Self.checkedSubtract(
                limitState.limitAmount,
                try Self.checkedAdd(alreadyBudgeted, limitState.fromLastMonth)
            )
            if toBudget >= room {
                toBudget = room
            }
        }

        return toBudget
    }

    private func remainderWeight(of category: Category) -> Double {
        category.entries.reduce(0) { partial, entry in
            guard entry.type == "remainder" else {
                return partial
            }
            return partial + (entry.weight ?? 1)
        }
    }

    private var remainderSmallestUnit: Int {
        guard currency.hideFraction, currency.decimalPlaces > 0 else {
            return 1
        }
        return NSDecimalNumber(decimal: currency.scale).intValue
    }
}
