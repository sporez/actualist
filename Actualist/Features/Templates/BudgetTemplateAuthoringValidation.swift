import Foundation

struct BudgetTemplateAuthoringContext: Equatable, Sendable {
    var today: Date
    var schedules: [BudgetTemplateScheduleOption]
    var incomeCategories: [BudgetTemplateIncomeOption]

    init(
        today: Date = Date(),
        schedules: [BudgetTemplateScheduleOption] = [],
        incomeCategories: [BudgetTemplateIncomeOption] = []
    ) {
        self.today = today
        self.schedules = schedules
        self.incomeCategories = incomeCategories
    }
}

enum BudgetTemplateAuthoringIssue: Equatable, Sendable {
    case invalidEntry(index: Int)
    case duplicateType(BudgetTemplateKind)
    case duplicateSpend
    case refillRequiresLimit
    case limitRequiresContributor
    case multipleLimits
    case scheduleNotFound(index: Int)
    case percentageSourceNotFound(index: Int)
    case percentageConflict(previous: Bool, source: String)
    case schedulePriorityMismatch
    case targetMonthMissing(index: Int)
    case targetMonthPast(index: Int)
    case spendStartMissing(index: Int)
    case spendStartAfterTarget(index: Int)
}

/// Pure list-level validation shared by the editor state and the definition
/// write boundary. It never mutates drafts or decides persisted money values.
enum BudgetTemplateAuthoringValidation {
    static func issues(
        for drafts: [BudgetTemplateDraft],
        context: BudgetTemplateAuthoringContext
    ) -> [BudgetTemplateAuthoringIssue] {
        var issues: [BudgetTemplateAuthoringIssue] = []
        if drafts.count > BudgetTemplateEngine.Bounds.maximumEntriesPerCategory {
            issues.append(.invalidEntry(index: drafts.count))
        }

        for (index, draft) in drafts.enumerated() {
            if !draft.isComplete {
                issues.append(.invalidEntry(index: index))
            }
            switch draft {
            case .schedule(let value):
                if !hasSchedule(value, context: context) {
                    issues.append(.scheduleNotFound(index: index))
                }
                if let adjustment = value.adjustment,
                   case .percent(let amount) = adjustment,
                   !(amount > -100 && amount <= 1_000) {
                    issues.append(.invalidEntry(index: index))
                }
            case .percentage(let value):
                if !hasPercentageSource(value.sourceCategory, previous: value.previous, context: context) {
                    issues.append(.percentageSourceNotFound(index: index))
                }
            case .dateTarget(let value):
                validateTarget(value, index: index, context: context, issues: &issues)
            case .average(let value):
                if let adjustment = value.adjustment,
                   case .percent(let amount) = adjustment,
                   !(amount > -100 && amount <= 1_000) {
                    issues.append(.invalidEntry(index: index))
                }
            default:
                break
            }
        }

        var singletonKinds: Set<BudgetTemplateKind> = []
        for draft in drafts where draft.kind.isSingleton {
            if !singletonKinds.insert(draft.kind).inserted {
                issues.append(.duplicateType(draft.kind))
            }
        }

        let limitCount = drafts.reduce(into: 0) { count, draft in
            if case .balanceLimit = draft { count += 1 }
        }
        if limitCount > 1 {
            issues.append(.multipleLimits)
        }
        let hasContributor = drafts.contains { draft in
            switch draft {
            case .goal, .balanceLimit, .refill:
                false
            default:
                true
            }
        }
        if drafts.contains(where: { if case .refill = $0 { true } else { false } })
                && limitCount != 1 {
            issues.append(.refillRequiresLimit)
        }
        if limitCount == 1 && !hasContributor {
            issues.append(.limitRequiresContributor)
        }

        let scheduleAndTargets = drafts.compactMap { draft -> Int? in
            switch draft {
            case .schedule(let value): value.priority
            case .dateTarget(let value) where !value.isSpend: value.priority
            default: nil
            }
        }
        if Set(scheduleAndTargets).count > 1 {
            issues.append(.schedulePriorityMismatch)
        }

        if drafts.filter({
            if case .dateTarget(let value) = $0 { return value.isSpend }
            return false
        }).count > 1 {
            issues.append(.duplicateSpend)
        }

        var percentageTotals: [String: Double] = [:]
        for draft in drafts {
            guard case .percentage(let value) = draft else { continue }
            let key = "\(value.previous)|\(value.sourceCategory.localizedLowercase)"
            percentageTotals[key, default: 0] += value.percent
        }
        for (key, total) in percentageTotals where total > 100 {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let previous = parts.first == "true"
            issues.append(.percentageConflict(previous: previous, source: parts.dropFirst().first ?? ""))
        }
        return issues
    }

    static func isValid(
        _ drafts: [BudgetTemplateDraft],
        context: BudgetTemplateAuthoringContext
    ) -> Bool {
        issues(for: drafts, context: context).isEmpty
    }

    private static func hasSchedule(
        _ value: BudgetTemplateDraft.Schedule,
        context: BudgetTemplateAuthoringContext
    ) -> Bool {
        if let scheduleId = value.scheduleId,
           !scheduleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return context.schedules.contains { $0.id == scheduleId }
        }
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && context.schedules.contains { $0.name == name }
    }

    private static func hasPercentageSource(
        _ source: String,
        previous: Bool,
        context: BudgetTemplateAuthoringContext
    ) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.localizedLowercase
        if lowered == "all income" { return true }
        if lowered == "available funds" { return !previous }
        return context.incomeCategories.contains {
            $0.id == trimmed || $0.name.localizedLowercase == lowered
        }
    }

    private static func validateTarget(
        _ value: BudgetTemplateDraft.DateTarget,
        index: Int,
        context: BudgetTemplateAuthoringContext,
        issues: inout [BudgetTemplateAuthoringIssue]
    ) {
        guard let target = try? BudgetTemplateCalendar.parseMonth(value.month) else {
            issues.append(.targetMonthMissing(index: index))
            return
        }
        let todayMonth = BudgetTemplateCalendar.currentMonthValue(now: context.today)
        if target < todayMonth && value.repeatInterval == nil {
            issues.append(.targetMonthPast(index: index))
        }
        if value.isSpend {
            guard let fromMonth = value.fromMonth,
                  let from = try? BudgetTemplateCalendar.parseMonth(fromMonth) else {
                issues.append(.spendStartMissing(index: index))
                return
            }
            if from > target {
                issues.append(.spendStartAfterTarget(index: index))
            }
        }
    }
}
