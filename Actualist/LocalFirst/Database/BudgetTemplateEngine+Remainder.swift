import Foundation

extension BudgetTemplateEngine {
    func distributeRemainder(
        categories: [String: Category],
        orderedCategoryIDs: [String],
        limitStates: [String: LimitState],
        budgetedByCategory: inout [String: Int],
        limitMetByCategory: inout [String: Bool],
        remainingAvailable: inout Int,
        contributions: inout [String: [Int]]
    ) throws {
        func remainderCategoryIDs() -> [String] {
            orderedCategoryIDs.filter { categoryID in
                guard let category = categories[categoryID] else {
                    return false
                }
                return remainderWeight(of: category) > 0
                    && limitMetByCategory[categoryID] != true
            }
        }

        var active = remainderCategoryIDs()
        while remainingAvailable > 0, !active.isEmpty {
            let totalWeight = active.reduce(0.0) { partial, categoryID in
                guard let category = categories[categoryID] else {
                    return partial
                }
                return partial + remainderWeight(of: category)
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
                    let carried = try Self.checkedAdd(
                        nextBudgeted,
                        limitState.fromLastMonth
                    )
                    if carried >= limitState.limitAmount {
                        limitMetByCategory[categoryID] = true
                    }
                }
                budgetedByCategory[categoryID] = try Self.checkedAdd(
                    budgetedByCategory[categoryID, default: 0],
                    allocated
                )
                remainingAvailable = try Self.checkedSubtract(remainingAvailable, allocated)
                try attributeRemainder(
                    allocated,
                    category: category,
                    categoryID: categoryID,
                    contributions: &contributions
                )
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
            toBudget = try removeFractionLikeActual(toBudget)
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
            guard entry.type == "remainder", let weight = entry.weight else {
                return partial
            }
            return partial + weight
        }
    }


    private func attributeRemainder(
        _ allocated: Int,
        category: Category,
        categoryID: String,
        contributions: inout [String: [Int]]
    ) throws {
        guard allocated > 0 else { return }
        let indexes = category.entries.indices.filter { category.entries[$0].type == "remainder" }
        guard !indexes.isEmpty else { return }
        if contributions[categoryID] == nil {
            contributions[categoryID] = Array(repeating: 0, count: category.entries.count)
        }
        let weights = indexes.map { category.entries[$0].weight ?? 0 }
        let weightSum = weights.reduce(0, +)
        var remaining = allocated
        for (offset, index) in indexes.enumerated() {
            let isLast = offset == indexes.count - 1
            let share: Int
            if isLast {
                share = remaining
            } else if weightSum > 0 {
                share = max(
                    0,
                    min(remaining, try Self.actualRound(Double(allocated) * (weights[offset] / weightSum)))
                )
            } else {
                share = 0
            }
            contributions[categoryID]![index] += share
            remaining -= share
        }
    }

    private var remainderSmallestUnit: Int {
        guard currency.hideFraction, currency.decimalPlaces > 0 else {
            return 1
        }
        return NSDecimalNumber(decimal: currency.scale).intValue
    }
}
