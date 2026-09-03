import Foundation

struct BudgetTemplateComputePlan: Equatable, Sendable {
    var writes: [BudgetTemplateEngine.Write]
    var leftover: Int
    var contributions: [String: [Int]]
}

extension BudgetTemplateEngine {
    func computeWrites(
        categories: [String: Category],
        orderedCategoryIDs: [String],
        monthValue: Int,
        availableBudget: Int,
        monthSources: MonthSources = MonthSources(),
        currentMonthValue: Int? = nil
    ) throws -> [Write] {
        try computePlan(
            categories: categories,
            orderedCategoryIDs: orderedCategoryIDs,
            monthValue: monthValue,
            availableBudget: availableBudget,
            monthSources: monthSources,
            currentMonthValue: currentMonthValue,
            skipAvailableClamp: false
        ).writes
    }

    /// Apply math plus per-entry contribution. `skipAvailableClamp` is the
    /// editor dry-run flag only. The write path must call `computeWrites`.
    func computePlan(
        categories: [String: Category],
        orderedCategoryIDs: [String],
        monthValue: Int,
        availableBudget: Int,
        monthSources: MonthSources = MonthSources(),
        currentMonthValue: Int? = nil,
        skipAvailableClamp: Bool
    ) throws -> BudgetTemplateComputePlan {
        guard !categories.isEmpty else {
            return BudgetTemplateComputePlan(writes: [], leftover: availableBudget, contributions: [:])
        }
        _ = try BudgetTemplateCalendar.validatedMonth(monthValue)
        let currentMonth = try BudgetTemplateCalendar.validatedMonth(
            currentMonthValue ?? monthValue
        )
        for category in categories.values {
            try validatePercentageSources(category.entries, monthSources: monthSources)
            try validateByScheduleAndSpend(
                category.entries,
                monthValue: monthValue,
                activeScheduleNames: monthSources.activeScheduleNames,
                activeScheduleIDs: monthSources.activeScheduleIDs
            )
        }

        let categoryIDs = orderedCategoryIDs.filter { categories[$0] != nil }
        let limitStates: [String: LimitState] = try Dictionary(
            uniqueKeysWithValues: categoryIDs.compactMap { categoryID -> (String, LimitState)? in
                guard let category = categories[categoryID] else {
                    return nil
                }
                return try limitState(for: category, monthValue: monthValue).map {
                    (categoryID, $0)
                }
            }
        )
        var remainingAvailable = availableBudget
        for categoryID in categoryIDs {
            guard let state = limitStates[categoryID] else {
                continue
            }
            remainingAvailable = try Self.checkedAdd(
                remainingAvailable,
                state.releasedExcess()
            )
        }

        var budgetedByCategory = Dictionary(
            uniqueKeysWithValues: categories.keys.map { ($0, 0) }
        )
        var fullAmountByCategory: [String: Int] = [:]
        var limitMetByCategory: [String: Bool] = [:]
        var contributions = Dictionary(
            uniqueKeysWithValues: categories.map { id, category in
                (id, Array(repeating: 0, count: category.entries.count))
            }
        )
        for categoryID in categoryIDs {
            guard let state = limitStates[categoryID], state.isInitiallyMet else {
                continue
            }
            let initial = try state.initialBudgetedAmount()
            budgetedByCategory[categoryID] = initial
            fullAmountByCategory[categoryID] = initial
            limitMetByCategory[categoryID] = true
        }
        let priorities = Set(categories.values.flatMap { category in
            category.entries.compactMap { entry -> Int? in
                guard Self.participatesInPriority(entry) else {
                    return nil
                }
                return entry.priority
            }
        }).sorted()

        for priority in priorities {
            let availableFunds = remainingAvailable
            for categoryID in categoryIDs {
                guard let category = categories[categoryID] else {
                    continue
                }
                let indexedEntries = category.entries.enumerated().filter {
                    Self.participatesInPriority($0.element) && $0.element.priority == priority
                }
                guard !indexedEntries.isEmpty,
                      limitMetByCategory[categoryID] != true else {
                    continue
                }

                var amount = 0
                var rawByIndex: [Int: Int] = [:]
                var ranBy = false
                var ranSchedule = false
                var byIndexes: [Int] = []
                var scheduleIndexes: [Int] = []
                for (index, entry) in indexedEntries {
                    switch entry.type {
                    case "by":
                        byIndexes.append(index)
                        if ranBy {
                            rawByIndex[index] = 0
                            continue
                        }
                        ranBy = true
                        let batch = try computeByAmount(
                            indexedEntries.map(\.element).filter { $0.type == "by" },
                            monthValue: monthValue,
                            fromLastMonth: category.fromLastMonth
                        )
                        amount = try Self.checkedAdd(amount, batch)
                        rawByIndex[index] = batch
                    case "schedule":
                        scheduleIndexes.append(index)
                        if ranSchedule {
                            rawByIndex[index] = 0
                            continue
                        }
                        ranSchedule = true
                        let batch = try computeScheduleAmount(
                            indexedEntries.map(\.element).filter { $0.type == "schedule" },
                            monthValue: monthValue,
                            category: category,
                            alreadyBudgeted: amount
                        )
                        amount = try Self.checkedAdd(amount, batch)
                        rawByIndex[index] = batch
                    default:
                        let part = try computeEntryAmount(
                            entry,
                            monthValue: monthValue,
                            currentMonthValue: currentMonth,
                            category: category,
                            limitState: limitStates[categoryID],
                            availableFunds: availableFunds,
                            monthSources: monthSources
                        )
                        amount = try Self.checkedAdd(amount, part)
                        rawByIndex[index] = part
                    }
                }

                if byIndexes.count > 1 {
                    try redistributeRaw(
                        indexes: byIndexes,
                        rawByIndex: &rawByIndex,
                        weights: byIndexes.map { index in
                            let entry = category.entries[index]
                            return (try? resolvedByTarget(entry, monthValue: monthValue).amount) ?? 0
                        }
                    )
                }
                if scheduleIndexes.count > 1 {
                    try redistributeRaw(
                        indexes: scheduleIndexes,
                        rawByIndex: &rawByIndex,
                        weights: scheduleIndexes.map { index in
                            let entry = category.entries[index]
                            guard let key = entry.scheduleLookupKey,
                                  let resolved = category.resolvedSchedules[key] else {
                                return 0
                            }
                            return max(0, resolved.monthlyRepeatingTarget)
                        }
                    )
                }

                if let limitState = limitStates[categoryID] {
                    let alreadyBudgeted = budgetedByCategory[categoryID, default: 0]
                    let availableBeforeLimit = max(
                        0,
                        try Self.checkedSubtract(
                            try Self.checkedSubtract(
                                limitState.limitAmount,
                                limitState.fromLastMonth
                            ),
                            alreadyBudgeted
                        )
                    )
                    if amount > availableBeforeLimit {
                        amount = availableBeforeLimit
                        limitMetByCategory[categoryID] = true
                    }
                }

                if currency.hideFraction {
                    amount = try removeFractionLikeActual(amount)
                }

                fullAmountByCategory[categoryID] = try Self.checkedAdd(
                    fullAmountByCategory[categoryID, default: 0],
                    amount
                )

                // Actual's "do not overbudget when using a priority" clamp gates on
                // `available < 0` where `available = budgetAvail - toBudget` (the
                // resulting availability), NOT on whether the amount is positive.
                // Editor dry-run passes skipAvailableClamp so empty To Budget still
                // shows demand. The write path must not.
                if priority > 0,
                   !category.isIncome,
                   remainingAvailable < amount,
                   !skipAvailableClamp {
                    amount = max(0, remainingAvailable)
                }

                let orderedIndexes = indexedEntries.map(\.offset)
                let shares = try Self.scaledShares(
                    rawByIndex: rawByIndex,
                    orderedIndexes: orderedIndexes,
                    total: amount
                )
                for (index, share) in shares {
                    contributions[categoryID]![index] = try Self.checkedAdd(
                        contributions[categoryID]![index],
                        share
                    )
                }

                budgetedByCategory[categoryID] = try Self.checkedAdd(
                    budgetedByCategory[categoryID, default: 0],
                    amount
                )
                if category.isIncome {
                    remainingAvailable = try Self.checkedAdd(
                        remainingAvailable,
                        amount
                    )
                } else {
                    remainingAvailable = try Self.checkedSubtract(
                        remainingAvailable,
                        amount
                    )
                }
            }
        }

        try distributeRemainder(
            categories: categories,
            orderedCategoryIDs: categoryIDs,
            limitStates: limitStates,
            budgetedByCategory: &budgetedByCategory,
            limitMetByCategory: &limitMetByCategory,
            remainingAvailable: &remainingAvailable,
            contributions: &contributions
        )

        let writes = try finalizeWrites(
            categories: categories,
            orderedCategoryIDs: categoryIDs,
            budgetedByCategory: budgetedByCategory,
            fullAmountByCategory: fullAmountByCategory
        )
        return BudgetTemplateComputePlan(
            writes: writes,
            leftover: remainingAvailable,
            contributions: contributions
        )
    }
}

extension BudgetTemplateEngine {
    fileprivate func redistributeRaw(
        indexes: [Int],
        rawByIndex: inout [Int: Int],
        weights: [Int]
    ) throws {
        let batch = indexes.reduce(0) { $0 + (rawByIndex[$1] ?? 0) }
        let shares = try Self.distributeTotal(batch, weights: weights)
        for (offset, index) in indexes.enumerated() {
            rawByIndex[index] = shares[offset]
        }
    }

    static func scaledShares(
        rawByIndex: [Int: Int],
        orderedIndexes: [Int],
        total: Int
    ) throws -> [Int: Int] {
        let scaledTotal = max(0, total)
        let rawTotal = rawByIndex.values.reduce(0, +)
        guard scaledTotal > 0, rawTotal != 0 else {
            return Dictionary(uniqueKeysWithValues: orderedIndexes.map { ($0, 0) })
        }
        let scale = Double(scaledTotal) / Double(rawTotal)
        var remaining = scaledTotal
        var result: [Int: Int] = [:]
        for (offset, index) in orderedIndexes.enumerated() {
            let isLast = offset == orderedIndexes.count - 1
            let raw = rawByIndex[index] ?? 0
            let share: Int
            if isLast {
                share = remaining
            } else {
                share = max(0, min(remaining, try actualRound(Double(raw) * scale)))
            }
            result[index] = share
            remaining -= share
        }
        return result
    }

    static func distributeTotal(_ total: Int, weights: [Int]) throws -> [Int] {
        guard total > 0, !weights.isEmpty else {
            return Array(repeating: 0, count: weights.count)
        }
        let weightSum = weights.reduce(0, +)
        var remaining = total
        var result = Array(repeating: 0, count: weights.count)
        for index in weights.indices {
            if index == weights.count - 1 {
                result[index] = remaining
                break
            }
            let share: Int
            if weightSum > 0 {
                share = max(
                    0,
                    min(
                        remaining,
                        try actualRound(Double(total) * Double(weights[index]) / Double(weightSum))
                    )
                )
            } else {
                share = 0
            }
            result[index] = share
            remaining -= share
        }
        return result
    }
}
