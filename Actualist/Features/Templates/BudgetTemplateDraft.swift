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
}
