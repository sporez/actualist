import Foundation

struct BudgetTemplateEngine {
    var currency: BudgetCurrency = .usd

    struct Category: Sendable {
        let entries: [BudgetTemplateEntry]
        let fromLastMonth: Int
        let copiedBudgetedByLookBack: [Int: Int]
        let isIncome: Bool
        let activityByMonth: [Int: Int]
        let firstRelevantMonth: Int?
        let budgetedByMonth: [Int: Int]
        let leftoverByMonth: [Int: Int]
        let spentByMonth: [Int: Int]
        let resolvedSchedules: [String: ResolvedSchedule]
        let lastMonthGoal: Int
        let previouslyBudgeted: Int

        init(
            entries: [BudgetTemplateEntry],
            fromLastMonth: Int,
            copiedBudgetedByLookBack: [Int: Int],
            isIncome: Bool = false,
            activityByMonth: [Int: Int] = [:],
            firstRelevantMonth: Int? = nil,
            budgetedByMonth: [Int: Int] = [:],
            leftoverByMonth: [Int: Int] = [:],
            spentByMonth: [Int: Int] = [:],
            resolvedSchedules: [String: ResolvedSchedule] = [:],
            lastMonthGoal: Int = 0,
            previouslyBudgeted: Int = 0
        ) {
            self.entries = entries
            self.fromLastMonth = fromLastMonth
            self.copiedBudgetedByLookBack = copiedBudgetedByLookBack
            self.isIncome = isIncome
            self.activityByMonth = activityByMonth
            self.firstRelevantMonth = firstRelevantMonth
            self.budgetedByMonth = budgetedByMonth
            self.leftoverByMonth = leftoverByMonth
            self.spentByMonth = spentByMonth
            self.resolvedSchedules = resolvedSchedules
            self.lastMonthGoal = lastMonthGoal
            self.previouslyBudgeted = previouslyBudgeted
        }
    }

    struct MonthSources: Sendable {
        var totalIncomeByLookBack: [Int: Int] = [:]
        var incomeActivityByCategoryID: [String: [Int: Int]] = [:]
        var incomeCategoryIDs: Set<String> = []
        var incomeCategoryIDByLocalizedName: [String: String] = [:]
        var activeScheduleNames: Set<String> = []
    }

    struct Write: Equatable, Sendable {
        let categoryID: String
        let amount: Int
        let goal: Int?
        let longGoal: Int?

        init(categoryID: String, amount: Int, goal: Int? = nil, longGoal: Int? = nil) {
            self.categoryID = categoryID
            self.amount = amount
            self.goal = goal
            self.longGoal = longGoal
        }
    }

    enum Bounds {
        static let signedTemplateAmount = -1_000_000_000.0...1_000_000_000.0
        static let nonnegativeAmount = 0.0...1_000_000_000.0
        static let percentage = 0.0...100.0
        static let priority = 0...1_000
        static let periodInterval = BudgetTemplateCalendar.periodInterval
        static let repeatInterval = 1...1_200
        static let lookBack = 0...1_200
        static let numMonths = 1...1_200
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
        try validateOneGoal(entries)
        try validateOneSpend(entries)
        let actionable = entries.filter { $0.setsBudget || $0.isGoal }
        guard !actionable.isEmpty else {
            return nil
        }
        guard actionable.count <= Bounds.maximumEntriesPerCategory else {
            throw LocalFirstError.unsupportedTemplate("too many template entries")
        }
        for entry in actionable {
            try validate(entry)
        }
        try validateInteractions(actionable.filter(\.setsBudget))
        return actionable
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
        availableBudget: Int,
        monthSources: MonthSources = MonthSources(),
        currentMonthValue: Int? = nil
    ) throws -> [Write] {
        guard !categories.isEmpty else {
            return []
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
                activeScheduleNames: monthSources.activeScheduleNames
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
                let entries = category.entries.filter {
                    Self.participatesInPriority($0) && $0.priority == priority
                }
                guard !entries.isEmpty,
                      limitMetByCategory[categoryID] != true else {
                    continue
                }

                var amount = 0
                var ranBy = false
                var ranSchedule = false
                for entry in entries {
                    switch entry.type {
                    case "by":
                        guard !ranBy else { continue }
                        ranBy = true
                        amount = try Self.checkedAdd(
                            amount,
                            computeByAmount(
                                entries.filter { $0.type == "by" },
                                monthValue: monthValue,
                                fromLastMonth: category.fromLastMonth
                            )
                        )
                    case "schedule":
                        guard !ranSchedule else { continue }
                        ranSchedule = true
                        amount = try Self.checkedAdd(
                            amount,
                            computeScheduleAmount(
                                entries.filter { $0.type == "schedule" },
                                monthValue: monthValue,
                                category: category,
                                alreadyBudgeted: amount
                            )
                        )
                    default:
                        amount = try Self.checkedAdd(
                            amount,
                            computeEntryAmount(
                                entry,
                                monthValue: monthValue,
                                currentMonthValue: currentMonth,
                                category: category,
                                limitState: limitStates[categoryID],
                                availableFunds: availableFunds,
                                monthSources: monthSources
                            )
                        )
                    }
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

        return try finalizeWrites(
            categories: categories,
            orderedCategoryIDs: categoryIDs,
            budgetedByCategory: budgetedByCategory,
            fullAmountByCategory: fullAmountByCategory
        )
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
        currentMonthValue: Int,
        category: Category,
        limitState: LimitState?,
        availableFunds: Int,
        monthSources: MonthSources
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
        case "average":
            return try computeAverageAmount(
                entry,
                monthValue: monthValue,
                currentMonthValue: currentMonthValue,
                category: category
            )
        case "percentage":
            return try computePercentageAmount(
                entry,
                availableFunds: availableFunds,
                monthSources: monthSources
            )
        case "spend":
            return try computeSpendAmount(
                entry,
                monthValue: monthValue,
                category: category
            )
        default:
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
    }

    private func computePercentageAmount(
        _ entry: BudgetTemplateEntry,
        availableFunds: Int,
        monthSources: MonthSources
    ) throws -> Int {
        guard let percent = entry.percentageAmount,
              Bounds.percentage.contains(percent) else {
            throw LocalFirstError.unsupportedTemplate("percentage")
        }
        let monthlyIncome = try percentageIncome(
            of: entry,
            availableFunds: availableFunds,
            monthSources: monthSources
        )
        return max(0, try Self.actualRound(Double(monthlyIncome) * (percent / 100)))
    }

    func resolvePercentageSource(
        _ entry: BudgetTemplateEntry,
        monthSources: MonthSources
    ) throws -> PercentageSource {
        let raw = entry.sourceCategory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            throw LocalFirstError.unsupportedTemplate("percentage")
        }
        let lowered = raw.localizedLowercase
        if lowered == "all income" {
            return .allIncome
        }
        if lowered == "available funds" {
            return .availableFunds
        }
        if monthSources.incomeCategoryIDs.contains(raw) {
            return .incomeCategory(raw)
        }
        if let categoryID = monthSources.incomeCategoryIDByLocalizedName[lowered] {
            return .incomeCategory(categoryID)
        }
        throw LocalFirstError.unsupportedTemplate(
            "Category \"\(raw)\" is not found in available income categories"
        )
    }

    enum PercentageSource: Equatable {
        case allIncome
        case availableFunds
        case incomeCategory(String)
    }

    private func percentageIncome(
        of entry: BudgetTemplateEntry,
        availableFunds: Int,
        monthSources: MonthSources
    ) throws -> Int {
        let lookBack = entry.previous == true ? 1 : 0
        switch try resolvePercentageSource(entry, monthSources: monthSources) {
        case .allIncome:
            return monthSources.totalIncomeByLookBack[lookBack] ?? 0
        case .availableFunds:
            return availableFunds
        case .incomeCategory(let categoryID):
            return monthSources.incomeActivityByCategoryID[categoryID]?[lookBack] ?? 0
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

    static func participatesInPriority(_ entry: BudgetTemplateEntry) -> Bool {
        entry.directive == "template" && entry.type != "remainder" && entry.type != "limit"
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
