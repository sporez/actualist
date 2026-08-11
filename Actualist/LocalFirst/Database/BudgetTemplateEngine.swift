import Foundation

struct BudgetTemplateEngine {
    struct Category: Sendable {
        let entries: [BudgetTemplateEntry]
        let fromLastMonth: Int
        let copiedBudgetedByLookBack: [Int: Int]
    }

    struct Write: Equatable, Sendable {
        let categoryID: String
        let amount: Int
    }

    private enum Bounds {
        static let amount = 0.0...1_000_000_000.0
        static let percentage = 0.0...100.0
        static let priority = 0...1_000
        static let periodInterval = 1...1_200
        static let repeatInterval = 1...1_200
        static let lookBack = 0...1_200
        static let year = 1...9_999
        static let maximumEntriesPerCategory = 1_000
    }

    private struct LimitState {
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

        let budgetEntries = entries.filter(\.setsBudget)
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
        _ = try Self.validatedMonth(monthValue)
        for entry in entries where entry.type == "by" {
            _ = try resolvedByTarget(entry, monthValue: monthValue)
        }
    }

    func computeWrites(
        categories: [String: Category],
        monthValue: Int,
        availableBudget: Int
    ) throws -> [Write] {
        guard !categories.isEmpty else {
            return []
        }
        _ = try Self.validatedMonth(monthValue)

        let limitStates = try Dictionary(
            uniqueKeysWithValues: categories.compactMap { item in
                try limitState(for: item.value).map { (item.key, $0) }
            }
        )
        var remainingAvailable = availableBudget
        for state in limitStates.values {
            remainingAvailable = try Self.checkedAdd(
                remainingAvailable,
                state.releasedExcess()
            )
        }

        var budgetedByCategory = Dictionary(
            uniqueKeysWithValues: categories.keys.map { ($0, 0) }
        )
        for (categoryID, state) in limitStates where state.isInitiallyMet {
            budgetedByCategory[categoryID] = try state.initialBudgetedAmount()
        }
        let priorities = Set(categories.values.flatMap { category in
            category.entries.map { $0.priority ?? 0 }
        }).sorted()

        for priority in priorities {
            for categoryID in categories.keys.sorted() {
                guard let category = categories[categoryID] else {
                    continue
                }
                let entries = category.entries.filter { ($0.priority ?? 0) == priority }
                guard !entries.isEmpty,
                      limitStates[categoryID]?.isInitiallyMet != true else {
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
                    }
                }

                if priority > 0, amount > 0, remainingAvailable < amount {
                    amount = max(0, remainingAvailable)
                }

                budgetedByCategory[categoryID] = try Self.checkedAdd(
                    budgetedByCategory[categoryID, default: 0],
                    amount
                )
                remainingAvailable = try Self.checkedSubtract(remainingAvailable, amount)
            }
        }

        return budgetedByCategory.map(Write.init(categoryID:amount:))
    }

    func periodicAmount(_ entry: BudgetTemplateEntry, monthValue: Int) throws -> Int {
        guard let amount = entry.amount,
              let periodAmount = entry.period?.amount,
              let period = entry.period?.period,
              Bounds.periodInterval.contains(periodAmount) else {
            throw LocalFirstError.unsupportedTemplate("periodic")
        }

        let amountInMinorUnits = try Self.amountToMinorUnits(amount)
        let monthStart = "\(Self.monthID(try Self.validatedMonth(monthValue)))-01"
        let starting = entry.starting?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let monthStartDate = Self.validatedDate(monthStart),
              let nextMonthStartDate = Calendar(identifier: .gregorian).date(
                byAdding: .month,
                value: 1,
                to: monthStartDate
              ) else {
            throw LocalFirstError.unsupportedTemplate("periodic month")
        }
        let startingDate: Date
        if let starting, !starting.isEmpty {
            guard let date = Self.validatedDate(starting) else {
                throw LocalFirstError.unsupportedTemplate("periodic start date")
            }
            startingDate = date
        } else {
            startingDate = monthStartDate
        }

        let occurrenceCount = try periodicOccurrenceCount(
            startingAt: startingDate,
            monthStart: monthStartDate,
            nextMonthStart: nextMonthStartDate,
            interval: periodAmount,
            period: period
        )
        let multiplied = amountInMinorUnits.multipliedReportingOverflow(by: occurrenceCount)
        guard !multiplied.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return multiplied.partialValue
    }

    func sourceMonthValue(for monthValue: Int, lookBack: Int) throws -> Int {
        guard Bounds.lookBack.contains(lookBack) else {
            throw LocalFirstError.unsupportedTemplate("copy")
        }
        return try Self.shiftedMonth(monthValue, by: -lookBack)
    }

    func shiftedPeriodicDate(_ dayID: String, by amount: Int, period: String) throws -> String {
        guard Bounds.periodInterval.contains(amount),
              let date = Self.validatedDate(dayID) else {
            throw LocalFirstError.unsupportedTemplate("periodic start date")
        }
        var components = DateComponents()
        switch period {
        case "day":
            components.day = amount
        case "week":
            let multiplied = amount.multipliedReportingOverflow(by: 7)
            guard !multiplied.overflow else {
                throw LocalFirstError.unsupportedTemplate("periodic interval")
            }
            components.day = multiplied.partialValue
        case "month":
            components.month = amount
        case "year":
            components.year = amount
        default:
            throw LocalFirstError.unsupportedTemplate("periodic \(period)")
        }
        guard let shifted = Calendar(identifier: .gregorian).date(
            byAdding: components,
            to: date
        ) else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        let shiftedID = Self.dayID(from: shifted)
        guard Self.validatedDate(shiftedID) != nil, shifted > date else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        return shiftedID
    }

    static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return result.partialValue
    }

    static func amountToMinorUnits(_ amount: Double) throws -> Int {
        // goal_def amounts are display decimals, not Actual's integer units.
        guard amount.isFinite, Bounds.amount.contains(amount) else {
            throw LocalFirstError.numericValueOutOfRange
        }
        let scaled = amount * 100
        guard scaled.isFinite,
              scaled >= Double(Int.min),
              scaled <= Double(Int.max) else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return Int(scaled.rounded())
    }

    private func validate(_ entry: BudgetTemplateEntry) throws {
        guard Bounds.priority.contains(entry.priority ?? 0) else {
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
        try validateAmount(entry.monthly, field: "monthly amount")
        try validateAmount(entry.amount, field: "amount")
        try validatePercentage(entry.percentage)
        try validateInterval(entry.period?.amount, field: "period interval")
        try validateLookBack(entry.lookBack)
        try validateRepeatInterval(entry.repeatInterval)
        try validateAmount(entry.limit?.amount, field: "limit amount")
        try validateAmount(entry.standaloneLimit?.amount, field: "limit amount")

        switch entry.type {
        case "simple":
            guard entry.monthly != nil || entry.limit != nil else {
                throw LocalFirstError.unsupportedTemplate("simple without monthly amount")
            }
            try validateBasicMonthlyLimit(entry.limit)
        case "periodic":
            guard entry.amount != nil,
                  let periodAmount = entry.period?.amount,
                  Bounds.periodInterval.contains(periodAmount),
                  let period = entry.period?.period,
                  ["day", "week", "month", "year"].contains(period) else {
                throw LocalFirstError.unsupportedTemplate("periodic")
            }
            if let starting = entry.starting,
               !starting.isEmpty,
               Self.validatedDate(starting) == nil {
                throw LocalFirstError.unsupportedTemplate("periodic start date")
            }
            try validateBasicMonthlyLimit(entry.limit)
        case "copy":
            guard let lookBack = entry.lookBack,
                  Bounds.lookBack.contains(lookBack),
                  entry.limit == nil else {
                throw LocalFirstError.unsupportedTemplate("copy")
            }
        case "by":
            guard entry.amount != nil,
                  Self.validMonth(entry.month),
                  entry.limit == nil,
                  entry.repeatInterval.map(Bounds.repeatInterval.contains) ?? true else {
                throw LocalFirstError.unsupportedTemplate("invalid by template")
            }
        case "limit":
            guard entry.standaloneLimit != nil else {
                throw LocalFirstError.unsupportedTemplate(
                    "up-to limit is missing its amount or period"
                )
            }
            try validateBasicMonthlyLimit(entry.standaloneLimit)
        case "refill":
            guard entry.limit == nil else {
                throw LocalFirstError.unsupportedTemplate("invalid refill template")
            }
        default:
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
    }

    private func validateAmount(_ amount: Double?, field: String) throws {
        guard let amount else {
            return
        }
        guard amount.isFinite, Bounds.amount.contains(amount) else {
            throw LocalFirstError.unsupportedTemplate("\(field) is outside the supported range")
        }
    }

    private func validatePercentage(_ percentage: Double?) throws {
        guard let percentage else {
            return
        }
        guard percentage.isFinite, Bounds.percentage.contains(percentage) else {
            throw LocalFirstError.unsupportedTemplate("percentage is outside the supported range")
        }
    }

    private func validateInterval(_ interval: Int?, field: String) throws {
        guard let interval else {
            return
        }
        guard Bounds.periodInterval.contains(interval) else {
            throw LocalFirstError.unsupportedTemplate("\(field) is outside the supported range")
        }
    }

    private func validateLookBack(_ lookBack: Int?) throws {
        guard let lookBack else {
            return
        }
        guard Bounds.lookBack.contains(lookBack) else {
            throw LocalFirstError.unsupportedTemplate(
                "look-back window is outside the supported range"
            )
        }
    }

    private func validateRepeatInterval(_ interval: Int?) throws {
        guard let interval else {
            return
        }
        guard Bounds.repeatInterval.contains(interval) else {
            throw LocalFirstError.unsupportedTemplate(
                "repeat interval is outside the supported range"
            )
        }
    }

    private func validateInteractions(_ entries: [BudgetTemplateEntry]) throws {
        let byPriorities = Set(
            entries.filter { $0.type == "by" }.map { $0.priority ?? 0 }
        )
        guard byPriorities.count <= 1 else {
            throw LocalFirstError.unsupportedTemplate(
                "all by templates in a category must use the same priority"
            )
        }

        let limits = entries.filter {
            $0.limit != nil || $0.standaloneLimit != nil
        }
        guard limits.count <= 1 else {
            throw LocalFirstError.unsupportedTemplate(
                "only one up-to limit is supported per category"
            )
        }

        if entries.contains(where: { $0.type == "refill" }) {
            guard limits.count == 1 else {
                throw LocalFirstError.unsupportedTemplate(
                    "refill requires exactly one up-to limit"
                )
            }
        }
    }

    private func validateBasicMonthlyLimit(_ limit: BudgetTemplateLimit?) throws {
        guard let limit else {
            return
        }
        guard let amount = limit.amount,
              amount.isFinite,
              Bounds.amount.contains(amount),
              limit.period == "monthly",
              limit.start == nil else {
            throw LocalFirstError.unsupportedTemplate(
                "only basic monthly up-to limits are supported"
            )
        }
    }

    private func limitState(for category: Category) throws -> LimitState? {
        let limits = category.entries.compactMap { entry in
            entry.type == "limit" ? entry.standaloneLimit : entry.limit
        }
        guard !limits.isEmpty else {
            return nil
        }
        guard limits.count == 1, let limit = limits.first, let amount = limit.amount else {
            throw LocalFirstError.unsupportedTemplate(
                "only one up-to limit is supported per category"
            )
        }

        return LimitState(
            limitAmount: try Self.amountToMinorUnits(amount),
            fromLastMonth: category.fromLastMonth,
            holdsExcess: limit.hold == true
        )
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
                return try Self.amountToMinorUnits(monthly)
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
              let initialTargetMonth = try? Self.parseMonth(month) else {
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
        var monthsRemaining = try Self.monthDistance(from: monthValue, to: targetMonth)
        if monthsRemaining < 0, let repeatPeriod {
            let overdueMonths = try Self.checkedSubtract(0, monthsRemaining)
            let adjusted = try Self.checkedAdd(overdueMonths, repeatPeriod - 1)
            let cycles = adjusted / repeatPeriod
            let shift = repeatPeriod.multipliedReportingOverflow(by: cycles)
            guard !shift.overflow else {
                throw LocalFirstError.unsupportedTemplate("invalid by repeat interval")
            }
            targetMonth = try Self.shiftedMonth(targetMonth, by: shift.partialValue)
            monthsRemaining = try Self.monthDistance(from: monthValue, to: targetMonth)
        }
        guard monthsRemaining >= 0 else {
            throw LocalFirstError.unsupportedTemplate(
                "by target month \(Self.monthID(initialTargetMonth)) has passed"
            )
        }

        return (
            amount: try Self.amountToMinorUnits(amount),
            monthsRemaining: monthsRemaining,
            repeatPeriod: repeatPeriod
        )
    }

    private func periodicOccurrenceCount(
        startingAt start: Date,
        monthStart: Date,
        nextMonthStart: Date,
        interval: Int,
        period: String
    ) throws -> Int {
        guard Bounds.periodInterval.contains(interval) else {
            throw LocalFirstError.unsupportedTemplate("periodic interval")
        }
        guard start < nextMonthStart else {
            return 0
        }

        switch period {
        case "day", "week":
            let step: Int
            if period == "week" {
                let multiplied = interval.multipliedReportingOverflow(by: 7)
                guard !multiplied.overflow else {
                    throw LocalFirstError.unsupportedTemplate("periodic interval")
                }
                step = multiplied.partialValue
            } else {
                step = interval
            }
            let calendar = Calendar(identifier: .gregorian)
            let firstIndex: Int
            if start < monthStart {
                guard let daysToMonth = calendar.dateComponents(
                    [.day],
                    from: start,
                    to: monthStart
                ).day else {
                    throw LocalFirstError.unsupportedTemplate("periodic date")
                }
                let adjusted = try Self.checkedAdd(daysToMonth, step - 1)
                firstIndex = adjusted / step
            } else {
                firstIndex = 0
            }
            guard let daysToEnd = calendar.dateComponents(
                [.day],
                from: start,
                to: nextMonthStart
            ).day,
                  daysToEnd > 0 else {
                return 0
            }
            let lastIndex = (daysToEnd - 1) / step
            guard lastIndex >= firstIndex else {
                return 0
            }
            return try Self.checkedAdd(
                try Self.checkedSubtract(lastIndex, firstIndex),
                1
            )
        case "month", "year":
            let firstIndex = try firstCalendarOccurrenceIndex(
                onOrAfter: monthStart,
                startingAt: start,
                interval: interval,
                period: period
            )
            let occurrence = try periodicOccurrenceDate(
                startingAt: start,
                index: firstIndex,
                interval: interval,
                period: period
            )
            return occurrence < nextMonthStart ? 1 : 0
        default:
            throw LocalFirstError.unsupportedTemplate("periodic \(period)")
        }
    }

    private func firstCalendarOccurrenceIndex(
        onOrAfter target: Date,
        startingAt start: Date,
        interval: Int,
        period: String
    ) throws -> Int {
        guard start < target else {
            return 0
        }
        let calendar = Calendar(identifier: .gregorian)
        let startComponents = calendar.dateComponents([.year, .month], from: start)
        let targetComponents = calendar.dateComponents([.year, .month], from: target)
        guard let startYear = startComponents.year,
              let startMonth = startComponents.month,
              let targetYear = targetComponents.year,
              let targetMonth = targetComponents.month else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }

        let distance: Int
        if period == "year" {
            distance = try Self.checkedSubtract(targetYear, startYear)
        } else {
            let yearDistance = try Self.checkedSubtract(targetYear, startYear)
            let monthDistance = yearDistance.multipliedReportingOverflow(by: 12)
            guard !monthDistance.overflow else {
                throw LocalFirstError.unsupportedTemplate("periodic date")
            }
            distance = try Self.checkedAdd(
                monthDistance.partialValue,
                try Self.checkedSubtract(targetMonth, startMonth)
            )
        }
        var index = max(0, distance / interval)
        var occurrence = try periodicOccurrenceDate(
            startingAt: start,
            index: index,
            interval: interval,
            period: period
        )
        if occurrence < target {
            index = try Self.checkedAdd(index, 1)
            occurrence = try periodicOccurrenceDate(
                startingAt: start,
                index: index,
                interval: interval,
                period: period
            )
        }
        guard occurrence >= target else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        return index
    }

    private func periodicOccurrenceDate(
        startingAt start: Date,
        index: Int,
        interval: Int,
        period: String
    ) throws -> Date {
        let multiplied = interval.multipliedReportingOverflow(by: index)
        guard !multiplied.overflow else {
            throw LocalFirstError.unsupportedTemplate("periodic interval")
        }
        let component: Calendar.Component = period == "year" ? .year : .month
        guard let occurrence = Calendar(identifier: .gregorian).date(
            byAdding: component,
            value: multiplied.partialValue,
            to: start
        ) else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        let occurrenceID = Self.dayID(from: occurrence)
        guard Self.validatedDate(occurrenceID) != nil else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        return occurrence
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

    private static func checkedSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return result.partialValue
    }

    private static func actualRound(_ amount: Double) throws -> Int {
        guard amount.isFinite,
              amount >= Double(Int.min),
              amount <= Double(Int.max) else {
            throw LocalFirstError.numericValueOutOfRange
        }
        return Int(floor(amount + 0.5))
    }

    private static func validMonth(_ month: String?) -> Bool {
        guard let month,
              let value = try? parseMonth(month),
              (try? validatedMonth(value)) != nil else {
            return false
        }
        return true
    }

    private static func parseMonth(_ month: String) throws -> Int {
        let normalized = month.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = normalized.replacingOccurrences(of: "-", with: "")
        guard compact.count == 6,
              let value = Int(compact) else {
            throw LocalFirstError.unsupportedTemplate("invalid by template")
        }
        return try validatedMonth(value)
    }

    private static func validatedMonth(_ month: Int) throws -> Int {
        let year = month / 100
        let monthNumber = month % 100
        guard Bounds.year.contains(year),
              (1...12).contains(monthNumber) else {
            throw LocalFirstError.unsupportedTemplate(
                "template month is outside the supported range"
            )
        }
        return month
    }

    private static func monthOrdinal(_ month: Int) throws -> Int {
        let month = try validatedMonth(month)
        return (month / 100 - 1) * 12 + (month % 100 - 1)
    }

    private static func monthDistance(from currentMonth: Int, to targetMonth: Int) throws -> Int {
        try checkedSubtract(monthOrdinal(targetMonth), monthOrdinal(currentMonth))
    }

    private static func shiftedMonth(_ month: Int, by offset: Int) throws -> Int {
        let ordinal = try monthOrdinal(month)
        let shifted = ordinal.addingReportingOverflow(offset)
        guard !shifted.overflow,
              shifted.partialValue >= 0,
              shifted.partialValue < Bounds.year.upperBound * 12 else {
            throw LocalFirstError.unsupportedTemplate(
                "template month is outside the supported range"
            )
        }
        let year = shifted.partialValue / 12 + 1
        let monthNumber = shifted.partialValue % 12 + 1
        return year * 100 + monthNumber
    }

    private static func monthID(_ month: Int) -> String {
        String(format: "%04d-%02d", month / 100, month % 100)
    }

    private static func validatedDate(_ dayID: String) -> Date? {
        let normalized = dayID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              Bounds.year.contains(year),
              let date = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: year, month: month, day: day)
              ),
              Self.dayID(from: date) == normalized else {
            return nil
        }
        return date
    }

    private static func dayID(from date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
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
