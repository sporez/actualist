import Foundation

struct BudgetTemplateEngine {
    var currency: BudgetCurrency = .usd

    struct Category: Sendable {
        let entries: [BudgetTemplateEntry]
        let fromLastMonth: Int
        let copiedBudgetedByLookBack: [Int: Int]
        let isIncome: Bool
    }

    struct Write: Equatable, Sendable {
        let categoryID: String
        let amount: Int
    }

    enum Bounds {
        static let signedTemplateAmount = -1_000_000_000.0...1_000_000_000.0
        static let nonnegativeAmount = 0.0...1_000_000_000.0
        static let percentage = 0.0...100.0
        static let priority = 0...1_000
        static let periodInterval = BudgetTemplateCalendar.periodInterval
        static let repeatInterval = 1...1_200
        static let lookBack = 0...1_200
        static let year = BudgetTemplateCalendar.year
        static let weight = 0.0...1_000_000.0
        static let maximumEntriesPerCategory = 1_000
    }

    struct LimitState {
        let limitAmount: Int
        let fromLastMonth: Int
        let holdsExcess: Bool

        var isInitiallyMet: Bool {
            fromLastMonth >= limitAmount
        }

        func initialBudgetedAmount() throws -> Int {
            guard isInitiallyMet, !holdsExcess else {
                return 0
            }
            return try Self.checkedSubtract(limitAmount, fromLastMonth)
        }

        func releasedExcess() throws -> Int {
            max(0, try Self.checkedSubtract(0, initialBudgetedAmount()))
        }

        private static func checkedSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
            try BudgetTemplateEngine.checkedSubtract(lhs, rhs)
        }
    }

    func decodeSupportedEntries(json: String) throws -> [BudgetTemplateEntry]? {
        guard let data = json.data(using: .utf8) else {
            throw LocalFirstError.unsupportedTemplate("template definition is not UTF-8")
        }
        let entries: [BudgetTemplateEntry]
        do {
            entries = try JSONDecoder().decode([BudgetTemplateEntry].self, from: data)
        } catch {
            throw LocalFirstError.unsupportedTemplate(decodingFailureReason(error))
        }

        for entry in entries {
            try validateDirective(entry)
        }
        let hasGoal = entries.contains {
            $0.directive == "goal" && $0.type == "goal"
        }
        let budgetEntries = entries.filter(\.setsBudget)
        // Goal-only categories stay a no-op until setGoal lands. Mixing a goal
        // with an executable budget template would apply only half of Actual's
        // intended state, so fail closed instead of writing a partial budget.
        if hasGoal, !budgetEntries.isEmpty {
            throw LocalFirstError.unsupportedTemplate(
                "goal writes are not supported locally yet"
            )
        }
        guard !budgetEntries.isEmpty else {
            return nil
        }
        guard budgetEntries.count <= Bounds.maximumEntriesPerCategory else {
            throw LocalFirstError.unsupportedTemplate("too many template entries")
        }
        for entry in budgetEntries {
            try validate(entry)
        }
        try validateInteractions(budgetEntries)
        return budgetEntries
    }

    func validate(_ entries: [BudgetTemplateEntry], for monthValue: Int) throws {
        _ = try BudgetTemplateCalendar.validatedMonth(monthValue)
        for entry in entries where entry.type == "by" {
            _ = try resolvedByTarget(entry, monthValue: monthValue)
        }
    }

    func computeWrites(
        categories: [String: Category],
        orderedCategoryIDs: [String],
        monthValue: Int,
        availableBudget: Int
    ) throws -> [Write] {
        guard !categories.isEmpty else {
            return []
        }
        _ = try BudgetTemplateCalendar.validatedMonth(monthValue)

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
        var limitMetByCategory: [String: Bool] = [:]
        for categoryID in categoryIDs {
            guard let state = limitStates[categoryID], state.isInitiallyMet else {
                continue
            }
            budgetedByCategory[categoryID] = try state.initialBudgetedAmount()
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
            for categoryID in categoryIDs {
                guard let category = categories[categoryID] else {
                    continue
                }
                let entries = category.entries.filter {
                    Self.participatesInPriority($0) && $0.priority == priority
                }
                guard !entries.isEmpty,
                      limitMetByCategory[categoryID] != true else {
                    continue
                }

                var amount = 0
                let byEntries = entries.filter { $0.type == "by" }
                if !byEntries.isEmpty {
                    amount = try Self.checkedAdd(
                        amount,
                        computeByAmount(
                            byEntries,
                            monthValue: monthValue,
                            fromLastMonth: category.fromLastMonth
                        )
                    )
                }
                for entry in entries where entry.type != "by" {
                    amount = try Self.checkedAdd(
                        amount,
                        computeEntryAmount(
                            entry,
                            monthValue: monthValue,
                            category: category,
                            limitState: limitStates[categoryID]
                        )
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

                if priority > 0,
                   !category.isIncome,
                   amount > 0,
                   remainingAvailable < amount {
                    amount = max(0, remainingAvailable)
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
            remainingAvailable: &remainingAvailable
        )

        return budgetedByCategory.map(Write.init(categoryID:amount:))
    }

    func periodicAmount(_ entry: BudgetTemplateEntry, monthValue: Int) throws -> Int {
        guard let amount = entry.amount,
              let periodAmount = entry.period?.amount,
              let period = entry.period?.period,
              Bounds.periodInterval.contains(periodAmount) else {
            throw LocalFirstError.unsupportedTemplate("periodic")
        }

        let amountInMinorUnits = try amountToMinorUnits(amount)
        let monthStartDate = try BudgetTemplateCalendar.monthStartDate(monthValue)
        let nextMonthStartDate = try BudgetTemplateCalendar.nextMonthStartDate(monthValue)
        let starting = entry.starting?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startingDate: Date
        if let starting, !starting.isEmpty {
            guard let date = BudgetTemplateCalendar.validatedDate(starting) else {
                throw LocalFirstError.unsupportedTemplate("periodic start date")
            }
            startingDate = date
        } else {
            startingDate = monthStartDate
        }

        let occurrenceCount = try BudgetTemplateCalendar.periodicOccurrenceCount(
            startingAt: startingDate,
            monthStart: monthStartDate,
            nextMonthStart: nextMonthStartDate,
            interval: periodAmount,
            period: period
        )
        return try Self.checkedMultiply(amountInMinorUnits, occurrenceCount)
    }

    func sourceMonthValue(for monthValue: Int, lookBack: Int) throws -> Int {
        guard Bounds.lookBack.contains(lookBack) else {
            throw LocalFirstError.unsupportedTemplate("copy")
        }
        return try BudgetTemplateCalendar.shiftedMonth(monthValue, by: -lookBack)
    }

    func shiftedPeriodicDate(_ dayID: String, by amount: Int, period: String) throws -> String {
        try BudgetTemplateCalendar.shiftedPeriodicDate(dayID, by: amount, period: period)
    }

    static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return result.partialValue
    }

    static func checkedSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return result.partialValue
    }

    static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return result.partialValue
    }

    func amountToMinorUnits(_ amount: Double) throws -> Int {
        // Actual uses Math.round(amount * 10**decimalPlaces). JS Math.round
        // ties toward +Infinity; do not use BudgetCurrency's Decimal .plain
        // rounding, which disagrees on negative halves.
        guard amount.isFinite, Bounds.signedTemplateAmount.contains(amount) else {
            throw LocalFirstError.numericValueOutOfRange
        }
        let scale = try Self.decimalScale(currency.decimalPlaces)
        let scaled = amount * scale
        guard scaled.isFinite else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return try Self.actualRound(scaled)
    }

    func removeFractionLikeActual(_ minorUnits: Int) throws -> Int {
        guard currency.hideFraction, currency.decimalPlaces > 0 else {
            return minorUnits
        }
        let integerScale = try Self.integerScale(currency.decimalPlaces)
        let display = Double(minorUnits) / Double(integerScale)
        let roundedDisplay = try Self.actualRound(display)
        return try Self.checkedMultiply(roundedDisplay, integerScale)
    }

    private func limitState(for category: Category, monthValue: Int) throws -> LimitState? {
        let limits = category.entries.compactMap(Self.effectiveLimit)
        guard !limits.isEmpty else {
            return nil
        }
        guard limits.count == 1, let limit = limits.first, let amount = limit.amount else {
            throw LocalFirstError.unsupportedTemplate(
                "only one up-to limit is supported per category"
            )
        }

        return LimitState(
            limitAmount: try limitAmount(limit, monthValue: monthValue, baseAmount: amount),
            fromLastMonth: category.fromLastMonth,
            holdsExcess: limit.hold == true
        )
    }

    private func limitAmount(
        _ limit: BudgetTemplateLimit,
        monthValue: Int,
        baseAmount: Double
    ) throws -> Int {
        let base = try amountToMinorUnits(baseAmount)
        switch limit.period {
        case "monthly":
            return base
        case "daily":
            return try Self.checkedMultiply(
                base,
                try BudgetTemplateCalendar.daysInMonth(monthValue)
            )
        case "weekly":
            guard let start = limit.start else {
                throw LocalFirstError.unsupportedTemplate(
                    "weekly limit requires a start date (YYYY-MM-DD)"
                )
            }
            return try Self.checkedMultiply(
                base,
                try BudgetTemplateCalendar.weeklyLimitOccurrenceCount(
                    startingAt: start,
                    monthValue: monthValue
                )
            )
        default:
            throw LocalFirstError.unsupportedTemplate(
                "only daily, weekly, and monthly up-to limits are supported"
            )
        }
    }

    private func computeEntryAmount(
        _ entry: BudgetTemplateEntry,
        monthValue: Int,
        category: Category,
        limitState: LimitState?
    ) throws -> Int {
        switch entry.type {
        case "simple":
            if let monthly = entry.monthly {
                return try amountToMinorUnits(monthly)
            }
            guard let limitState else {
                throw LocalFirstError.unsupportedTemplate("simple without monthly amount")
            }
            return try Self.checkedSubtract(
                limitState.limitAmount,
                limitState.fromLastMonth
            )
        case "periodic":
            return try periodicAmount(entry, monthValue: monthValue)
        case "copy":
            guard let lookBack = entry.lookBack,
                  Bounds.lookBack.contains(lookBack),
                  let copiedBudgeted = category.copiedBudgetedByLookBack[lookBack] else {
                throw LocalFirstError.unsupportedTemplate("copy")
            }
            return copiedBudgeted
        case "limit":
            return 0
        case "refill":
            guard let limitState else {
                throw LocalFirstError.unsupportedTemplate("refill without up-to limit")
            }
            return try Self.checkedSubtract(
                limitState.limitAmount,
                limitState.fromLastMonth
            )
        default:
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
    }

    private func computeByAmount(
        _ entries: [BudgetTemplateEntry],
        monthValue: Int,
        fromLastMonth: Int
    ) throws -> Int {
        var targets: [(amount: Int, monthsRemaining: Int, repeatPeriod: Int?)] = []
        targets.reserveCapacity(entries.count)
        for entry in entries {
            targets.append(try resolvedByTarget(entry, monthValue: monthValue))
        }

        guard let shortestTarget = targets.map(\.monthsRemaining).min() else {
            return 0
        }

        var totalNeeded = 0
        for target in targets {
            if target.monthsRemaining > shortestTarget, let repeatPeriod = target.repeatPeriod {
                let remainingRepeatMonths = try Self.checkedAdd(
                    try Self.checkedSubtract(repeatPeriod, target.monthsRemaining),
                    shortestTarget
                )
                totalNeeded = try Self.checkedAdd(
                    totalNeeded,
                    try Self.actualRound(
                        Double(target.amount)
                            / Double(repeatPeriod)
                            * Double(remainingRepeatMonths)
                    )
                )
            } else if target.monthsRemaining > shortestTarget {
                totalNeeded = try Self.checkedAdd(
                    totalNeeded,
                    try Self.actualRound(
                        Double(target.amount)
                            / Double(try Self.checkedAdd(target.monthsRemaining, 1))
                            * Double(try Self.checkedAdd(shortestTarget, 1))
                    )
                )
            } else {
                totalNeeded = try Self.checkedAdd(totalNeeded, target.amount)
            }
        }

        return try Self.actualRound(
            Double(try Self.checkedSubtract(totalNeeded, fromLastMonth))
                / Double(try Self.checkedAdd(shortestTarget, 1))
        )
    }

    private func resolvedByTarget(
        _ entry: BudgetTemplateEntry,
        monthValue: Int
    ) throws -> (amount: Int, monthsRemaining: Int, repeatPeriod: Int?) {
        guard let amount = entry.amount,
              let month = entry.month,
              let initialTargetMonth = try? BudgetTemplateCalendar.parseMonth(month) else {
            throw LocalFirstError.unsupportedTemplate("invalid by template")
        }

        let repeatPeriod: Int?
        if entry.annual == true {
            let years = entry.repeatInterval ?? 1
            let multiplied = years.multipliedReportingOverflow(by: 12)
            guard !multiplied.overflow else {
                throw LocalFirstError.unsupportedTemplate("invalid by repeat interval")
            }
            repeatPeriod = multiplied.partialValue
        } else {
            repeatPeriod = entry.repeatInterval
        }

        var targetMonth = initialTargetMonth
        var monthsRemaining = try BudgetTemplateCalendar.monthDistance(
            from: monthValue,
            to: targetMonth
        )
        if monthsRemaining < 0, let repeatPeriod {
            let overdueMonths = try Self.checkedSubtract(0, monthsRemaining)
            let adjusted = try Self.checkedAdd(
                overdueMonths,
                try Self.checkedSubtract(repeatPeriod, 1)
            )
            let cycles = adjusted / repeatPeriod
            let shift = repeatPeriod.multipliedReportingOverflow(by: cycles)
            guard !shift.overflow else {
                throw LocalFirstError.unsupportedTemplate("invalid by repeat interval")
            }
            targetMonth = try BudgetTemplateCalendar.shiftedMonth(
                targetMonth,
                by: shift.partialValue
            )
            monthsRemaining = try BudgetTemplateCalendar.monthDistance(
                from: monthValue,
                to: targetMonth
            )
        }
        guard monthsRemaining >= 0 else {
            throw LocalFirstError.unsupportedTemplate(
                "by target month \(BudgetTemplateCalendar.monthID(initialTargetMonth)) has passed"
            )
        }

        return (
            amount: try amountToMinorUnits(amount),
            monthsRemaining: monthsRemaining,
            repeatPeriod: repeatPeriod
        )
    }

    private func decodingFailureReason(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return "can't decode \(Self.codingPath(context)): \(context.debugDescription)"
        case DecodingError.valueNotFound(_, let context):
            return "can't decode \(Self.codingPath(context)): \(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            return "can't decode \(Self.codingPath(context)).\(key.stringValue): missing required field"
        case DecodingError.dataCorrupted(let context):
            return "can't decode \(Self.codingPath(context)): \(context.debugDescription)"
        default:
            return "unreadable template definition"
        }
    }

    private static func participatesInPriority(_ entry: BudgetTemplateEntry) -> Bool {
        entry.type != "remainder" && entry.type != "limit"
    }

    static func actualRound(_ amount: Double) throws -> Int {
        guard amount.isFinite,
              amount >= Double(Int.min),
              amount <= Double(Int.max) else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return Int(floor(amount + 0.5))
    }

    static func decimalScale(_ decimalPlaces: Int) throws -> Double {
        guard (0...15).contains(decimalPlaces) else {
            throw LocalFirstError.numericValueOutOfRange
        }
        let scale = pow(10.0, Double(decimalPlaces))
        guard scale.isFinite, scale > 0 else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return scale
    }

    static func integerScale(_ decimalPlaces: Int) throws -> Int {
        guard decimalPlaces >= 0 else {
            throw LocalFirstError.numericValueOutOfRange
        }
        var scale = 1
        for _ in 0..<decimalPlaces {
            scale = try checkedMultiply(scale, 10)
        }
        return scale
    }

    private static func codingPath(_ context: DecodingError.Context) -> String {
        var path = "template"
        for key in context.codingPath {
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += ".\(key.stringValue)"
            }
        }
        return path
    }
}
