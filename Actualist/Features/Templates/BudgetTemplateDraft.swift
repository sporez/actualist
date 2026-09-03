import Foundation

/// Optional nested up-to / hold cap on a Cut A monthly Fixed template.
struct BudgetTemplateUpToHold: Equatable, Sendable {
    var amount: Double
    var hold: Bool
    var period: String
    var start: String?
}

/// Typed Cut A template draft. Loading `simple` becomes monthly Fixed; saving
/// always emits web's monthly `periodic` shape.
enum BudgetTemplateDraft: Equatable, Sendable {
    struct MonthlyFixed: Equatable, Sendable {
        var amount: Double
        var priority: Int
        var starting: String
        var upTo: BudgetTemplateUpToHold?
    }

    struct Copy: Equatable, Sendable {
        var lookBack: Int
        var priority: Int
    }

    struct Average: Equatable, Sendable {
        var numMonths: Int
        var priority: Int
    }

    struct Schedule: Equatable, Sendable {
        var name: String
        var scheduleId: String?
        var priority: Int
    }

    struct Remainder: Equatable, Sendable {
        var weight: Double
    }

    struct Goal: Equatable, Sendable {
        var amount: Double
    }

    case monthlyFixed(MonthlyFixed)
    case copy(Copy)
    case average(Average)
    case schedule(Schedule)
    case remainder(Remainder)
    case goal(Goal)

    static func monthlyFixed(
        amount: Double = 100,
        priority: Int = BudgetTemplateDefinition.defaultPriority,
        now: Date = Date(),
        upTo: BudgetTemplateUpToHold? = nil
    ) -> BudgetTemplateDraft {
        .monthlyFixed(
            MonthlyFixed(
                amount: amount,
                priority: priority,
                starting: BudgetTemplateDefinition.firstDayOfCurrentMonth(now: now),
                upTo: upTo
            )
        )
    }

    static func copy(
        lookBack: Int = 1,
        priority: Int = BudgetTemplateDefinition.defaultPriority
    ) -> BudgetTemplateDraft {
        .copy(Copy(lookBack: lookBack, priority: priority))
    }

    static func average(
        numMonths: Int = 3,
        priority: Int = BudgetTemplateDefinition.defaultPriority
    ) -> BudgetTemplateDraft {
        .average(Average(numMonths: numMonths, priority: priority))
    }

    static func schedule(
        name: String = "",
        scheduleId: String? = nil,
        priority: Int = BudgetTemplateDefinition.defaultPriority
    ) -> BudgetTemplateDraft {
        .schedule(Schedule(name: name, scheduleId: scheduleId, priority: priority))
    }

    static func remainder(weight: Double = 1) -> BudgetTemplateDraft {
        .remainder(Remainder(weight: weight))
    }

    static func goal(amount: Double = 1_000) -> BudgetTemplateDraft {
        .goal(Goal(amount: amount))
    }

    var cutAKind: BudgetTemplateCutAKind {
        switch self {
        case .monthlyFixed: .monthlyFixed
        case .copy: .copy
        case .average: .average
        case .schedule: .schedule
        case .remainder: .remainder
        case .goal: .goal
        }
    }

    var showsPriority: Bool {
        switch self {
        case .monthlyFixed, .copy, .average, .schedule:
            true
        case .remainder, .goal:
            false
        }
    }

    var showsContribution: Bool {
        if case .goal = self {
            return false
        }
        return true
    }

    /// Whether this draft can encode as a Cut A `goal_def` entry.
    var isComplete: Bool {
        switch self {
        case .monthlyFixed(let value):
            guard value.amount.isFinite,
                  BudgetTemplateEngine.Bounds.signedTemplateAmount.contains(value.amount),
                  BudgetTemplateEngine.Bounds.priority.contains(value.priority) else {
                return false
            }
            guard let upTo = value.upTo else {
                return true
            }
            return upTo.amount.isFinite
                && BudgetTemplateEngine.Bounds.nonnegativeAmount.contains(upTo.amount)
        case .copy(let value):
            return BudgetTemplateEngine.Bounds.lookBack.contains(value.lookBack)
                && BudgetTemplateEngine.Bounds.priority.contains(value.priority)
        case .average(let value):
            return BudgetTemplateEngine.Bounds.numMonths.contains(value.numMonths)
                && BudgetTemplateEngine.Bounds.priority.contains(value.priority)
        case .schedule(let value):
            let hasID = !(value.scheduleId ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            let hasName = !value.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return (hasID || hasName)
                && BudgetTemplateEngine.Bounds.priority.contains(value.priority)
        case .remainder(let value):
            return value.weight.isFinite
                && BudgetTemplateEngine.Bounds.weight.contains(value.weight)
        case .goal(let value):
            return value.amount.isFinite
                && BudgetTemplateEngine.Bounds.signedTemplateAmount.contains(value.amount)
        }
    }
}
