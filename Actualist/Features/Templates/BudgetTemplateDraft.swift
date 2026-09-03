import Foundation

enum BudgetTemplateCadence: String, CaseIterable, Equatable, Sendable {
    case day
    case week
    case month
    case year
}

enum BudgetTemplateLimitPeriod: String, CaseIterable, Equatable, Sendable {
    case daily
    case weekly
    case monthly
}

enum BudgetTemplateAdjustment: Equatable, Sendable {
    case fixed(Double)
    case percent(Double)

    var value: Double {
        switch self {
        case .fixed(let value), .percent(let value): value
        }
    }

    var type: String {
        switch self {
        case .fixed: "fixed"
        case .percent: "percent"
        }
    }
}

/// Optional nested cap retained for Cut A's existing fixed form and for
/// decoding legacy definitions until the standalone Limit editor lands.
struct BudgetTemplateUpToHold: Equatable, Sendable {
    var amount: Double
    var hold: Bool
    var period: String
    var start: String?
}

/// Typed editor-owned representation of an Actual template definition.
///
/// The definition codec owns conversion to and from Actual's JSON. These
/// values intentionally carry authoring metadata such as `description`; the
/// apply engine's `BudgetTemplateEntry` remains a separate calculation model.
enum BudgetTemplateDraft: Equatable, Sendable {
    struct MonthlyFixed: Equatable, Sendable {
        var amount: Double
        var priority: Int
        var starting: String
        var upTo: BudgetTemplateUpToHold?
        var cadence: BudgetTemplateCadence = .month
        var interval: Int = 1
        var description: String?
    }

    struct DateTarget: Equatable, Sendable {
        var amount: Double
        var month: String
        var priority: Int
        var repeatInterval: Int?
        var annual: Bool
        var fromMonth: String?
        var isSpend: Bool
        var description: String?
    }

    struct Percentage: Equatable, Sendable {
        var percent: Double
        var sourceCategory: String
        var previous: Bool
        var priority: Int
        var description: String?
    }

    struct BalanceLimit: Equatable, Sendable {
        var amount: Double
        var hold: Bool
        var period: BudgetTemplateLimitPeriod
        var start: String?
        var description: String?
    }

    struct Refill: Equatable, Sendable {
        var priority: Int
        var description: String?
    }

    struct Copy: Equatable, Sendable {
        var lookBack: Int
        var priority: Int
        /// Actual retains this legacy field but ignores it when applying Copy.
        var legacyLimit: BudgetTemplateUpToHold? = nil
        var description: String?
    }

    struct Average: Equatable, Sendable {
        var numMonths: Int
        var priority: Int
        var adjustment: BudgetTemplateAdjustment? = nil
        var description: String?
    }

    struct Schedule: Equatable, Sendable {
        var name: String
        var scheduleId: String?
        var priority: Int
        var full: Bool = false
        var adjustment: BudgetTemplateAdjustment? = nil
        var description: String?
    }

    struct Remainder: Equatable, Sendable {
        var weight: Double
        var legacyLimit: BudgetTemplateUpToHold? = nil
        var description: String?
    }

    struct Goal: Equatable, Sendable {
        var amount: Double
        var description: String?
    }

    case monthlyFixed(MonthlyFixed)
    case dateTarget(DateTarget)
    case percentage(Percentage)
    case balanceLimit(BalanceLimit)
    case refill(Refill)
    case copy(Copy)
    case average(Average)
    case schedule(Schedule)
    case remainder(Remainder)
    case goal(Goal)

    static func monthlyFixed(
        amount: Double = 100,
        priority: Int = BudgetTemplateDefinition.defaultPriority,
        now: Date = Date(),
        upTo: BudgetTemplateUpToHold? = nil,
        description: String? = nil
    ) -> BudgetTemplateDraft {
        .monthlyFixed(
            MonthlyFixed(
                amount: amount,
                priority: priority,
                starting: BudgetTemplateDefinition.firstDayOfCurrentMonth(now: now),
                upTo: upTo,
                description: normalizedDescription(description)
            )
        )
    }

    static func dateTarget(
        amount: Double = 1_200,
        month: String? = nil,
        priority: Int = BudgetTemplateDefinition.defaultPriority,
        repeatInterval: Int? = 1,
        annual: Bool = true,
        fromMonth: String? = nil,
        isSpend: Bool? = nil,
        description: String? = nil,
        now: Date = Date()
    ) -> BudgetTemplateDraft {
        .dateTarget(
            DateTarget(
                amount: amount,
                month: month ?? defaultDateTargetMonth(now: now),
                priority: priority,
                repeatInterval: repeatInterval,
                annual: annual,
                fromMonth: fromMonth,
                isSpend: isSpend ?? (fromMonth != nil),
                description: normalizedDescription(description)
            )
        )
    }

    static func percentage(
        percent: Double = 15,
        sourceCategory: String = "all income",
        previous: Bool = false,
        priority: Int = BudgetTemplateDefinition.defaultPriority,
        description: String? = nil
    ) -> BudgetTemplateDraft {
        .percentage(
            Percentage(
                percent: percent,
                sourceCategory: sourceCategory,
                previous: previous,
                priority: priority,
                description: normalizedDescription(description)
            )
        )
    }

    static func balanceLimit(
        amount: Double = 500,
        hold: Bool = false,
        period: BudgetTemplateLimitPeriod = .monthly,
        start: String? = nil,
        description: String? = nil
    ) -> BudgetTemplateDraft {
        .balanceLimit(
            BalanceLimit(
                amount: amount,
                hold: hold,
                period: period,
                start: start,
                description: normalizedDescription(description)
            )
        )
    }

    static func refill(
        priority: Int = BudgetTemplateDefinition.defaultPriority,
        description: String? = nil
    ) -> BudgetTemplateDraft {
        .refill(Refill(priority: priority, description: normalizedDescription(description)))
    }

    static func copy(
        lookBack: Int = 1,
        priority: Int = BudgetTemplateDefinition.defaultPriority,
        legacyLimit: BudgetTemplateUpToHold? = nil,
        description: String? = nil
    ) -> BudgetTemplateDraft {
        .copy(
            Copy(
                lookBack: lookBack,
                priority: priority,
                legacyLimit: legacyLimit,
                description: normalizedDescription(description)
            )
        )
    }

    static func average(
        numMonths: Int = 3,
        priority: Int = BudgetTemplateDefinition.defaultPriority,
        adjustment: BudgetTemplateAdjustment? = nil,
        description: String? = nil
    ) -> BudgetTemplateDraft {
        .average(
            Average(
                numMonths: numMonths,
                priority: priority,
                adjustment: adjustment,
                description: normalizedDescription(description)
            )
        )
    }

    static func schedule(
        name: String = "",
        scheduleId: String? = nil,
        priority: Int = BudgetTemplateDefinition.defaultPriority,
        full: Bool = false,
        adjustment: BudgetTemplateAdjustment? = nil,
        description: String? = nil
    ) -> BudgetTemplateDraft {
        .schedule(
            Schedule(
                name: name,
                scheduleId: scheduleId,
                priority: priority,
                full: full,
                adjustment: adjustment,
                description: normalizedDescription(description)
            )
        )
    }

    static func remainder(
        weight: Double = 1,
        legacyLimit: BudgetTemplateUpToHold? = nil,
        description: String? = nil
    ) -> BudgetTemplateDraft {
        .remainder(
            Remainder(
                weight: weight,
                legacyLimit: legacyLimit,
                description: normalizedDescription(description)
            )
        )
    }

    static func goal(amount: Double = 1_000, description: String? = nil) -> BudgetTemplateDraft {
        .goal(Goal(amount: amount, description: normalizedDescription(description)))
    }

    var kind: BudgetTemplateKind {
        switch self {
        case .monthlyFixed: .monthlyFixed
        case .dateTarget: .dateTarget
        case .percentage: .percentage
        case .balanceLimit: .balanceLimit
        case .refill: .refill
        case .copy: .copy
        case .average: .average
        case .schedule: .schedule
        case .remainder: .remainder
        case .goal: .goal
        }
    }

    var description: String? {
        switch self {
        case .monthlyFixed(let value): value.description
        case .dateTarget(let value): value.description
        case .percentage(let value): value.description
        case .balanceLimit(let value): value.description
        case .refill(let value): value.description
        case .copy(let value): value.description
        case .average(let value): value.description
        case .schedule(let value): value.description
        case .remainder(let value): value.description
        case .goal(let value): value.description
        }
    }

    var showsPriority: Bool {
        switch self {
        case .monthlyFixed, .dateTarget, .percentage, .refill, .copy, .average, .schedule:
            true
        case .balanceLimit, .remainder, .goal:
            false
        }
    }

    var showsContribution: Bool {
        if case .goal = self { return false }
        if case .balanceLimit = self { return false }
        return true
    }

    /// Whether this draft can be encoded as a supported editor definition.
    /// Cross-entry rules are owned by `BudgetTemplateAuthoringValidator`.
    var isComplete: Bool {
        switch self {
        case .monthlyFixed(let value):
            guard value.amount.isFinite,
                  BudgetTemplateEngine.Bounds.signedTemplateAmount.contains(value.amount),
                  BudgetTemplateEngine.Bounds.priority.contains(value.priority),
                  BudgetTemplateEngine.Bounds.periodInterval.contains(value.interval),
                  BudgetTemplateCalendar.validatedDate(value.starting) != nil else { return false }
            guard let upTo = value.upTo else { return true }
            return isComplete(upTo)
        case .dateTarget(let value):
            return value.amount.isFinite
                && BudgetTemplateEngine.Bounds.signedTemplateAmount.contains(value.amount)
                && BudgetTemplateEngine.Bounds.priority.contains(value.priority)
                && value.repeatInterval.map(BudgetTemplateEngine.Bounds.repeatInterval.contains) ?? true
        case .percentage(let value):
            return value.percent > 0
                && BudgetTemplateEngine.Bounds.percentage.contains(value.percent)
                && BudgetTemplateEngine.Bounds.priority.contains(value.priority)
                && !value.sourceCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .balanceLimit(let value):
            return value.amount.isFinite
                && BudgetTemplateEngine.Bounds.nonnegativeAmount.contains(value.amount)
                && isComplete(value.start, period: value.period)
        case .refill(let value):
            return BudgetTemplateEngine.Bounds.priority.contains(value.priority)
        case .copy(let value):
            return BudgetTemplateEngine.Bounds.lookBack.contains(value.lookBack)
                && BudgetTemplateEngine.Bounds.priority.contains(value.priority)
                && (value.legacyLimit.map(isComplete) ?? true)
        case .average(let value):
            return BudgetTemplateEngine.Bounds.numMonths.contains(value.numMonths)
                && BudgetTemplateEngine.Bounds.priority.contains(value.priority)
                && (value.adjustment.map(isComplete) ?? true)
        case .schedule(let value):
            let hasID = !(value.scheduleId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasName = !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (hasID || hasName)
                && BudgetTemplateEngine.Bounds.priority.contains(value.priority)
                && (value.adjustment.map(isComplete) ?? true)
        case .remainder(let value):
            return value.weight.isFinite
                && BudgetTemplateEngine.Bounds.weight.contains(value.weight)
                && (value.legacyLimit.map(isComplete) ?? true)
        case .goal(let value):
            return value.amount.isFinite
                && BudgetTemplateEngine.Bounds.signedTemplateAmount.contains(value.amount)
        }
    }

    private func isComplete(_ value: BudgetTemplateUpToHold) -> Bool {
        value.amount.isFinite
            && BudgetTemplateEngine.Bounds.nonnegativeAmount.contains(value.amount)
            && BudgetTemplateLimitPeriod(rawValue: value.period) != nil
            && (value.start == nil || value.start.flatMap(BudgetTemplateCalendar.validatedDate) != nil)
            && (value.period != BudgetTemplateLimitPeriod.weekly.rawValue
                || value.start.flatMap(BudgetTemplateCalendar.validatedDate) != nil)
    }

    private func isComplete(_ value: String?, period: BudgetTemplateLimitPeriod) -> Bool {
        if period == .weekly {
            return value.flatMap(BudgetTemplateCalendar.validatedDate) != nil
        }
        return value == nil || value.flatMap(BudgetTemplateCalendar.validatedDate) != nil
    }

    private func isComplete(_ value: BudgetTemplateAdjustment) -> Bool {
        guard value.value.isFinite else { return false }
        switch value {
        case .fixed:
            return BudgetTemplateEngine.Bounds.signedTemplateAmount.contains(value.value)
        case .percent:
            return value.value > -100 && value.value <= 1_000
        }
    }
}

private func defaultDateTargetMonth(now: Date) -> String {
    let currentMonth = BudgetTemplateCalendar.currentMonthValue(now: now)
    let targetMonth = (try? BudgetTemplateCalendar.shiftedMonth(currentMonth, by: 12)) ?? currentMonth
    return BudgetTemplateCalendar.monthID(targetMonth)
}

private func normalizedDescription(_ value: String?) -> String? {
    guard let value,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return value
}
