import Foundation

extension BudgetTemplateEngine {
    // Actual's checkLimit() only treats limits on simple, periodic, remainder,
    // and standalone type == "limit" as active. Copy templates may carry a
    // `limit` field from the note parser; Current Actual ignores it at runtime.
    static func effectiveLimit(of entry: BudgetTemplateEntry) -> BudgetTemplateLimit? {
        switch entry.type {
        case "limit":
            return entry.standaloneLimit
        case "simple", "periodic", "remainder":
            return entry.limit
        default:
            return nil
        }
    }

    static func hasEffectiveLimit(_ entry: BudgetTemplateEntry) -> Bool {
        effectiveLimit(of: entry) != nil
    }

    func validateDirective(_ entry: BudgetTemplateEntry) throws {
        guard let directive = entry.directive?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directive.isEmpty else {
            throw LocalFirstError.unsupportedTemplate("template is missing a directive")
        }
        switch (directive, entry.type) {
        case ("template", "error"):
            throw LocalFirstError.unsupportedTemplate(
                "error type requires directive error"
            )
        case ("template", _):
            break
        case ("goal", "goal"):
            break
        case ("error", "error"):
            break
        case ("goal", _):
            throw LocalFirstError.unsupportedTemplate(
                "goal directive requires type goal"
            )
        case ("error", _):
            throw LocalFirstError.unsupportedTemplate(
                "error directive requires type error"
            )
        default:
            throw LocalFirstError.unsupportedTemplate(
                "unsupported template directive"
            )
        }
    }

    func validate(_ entry: BudgetTemplateEntry) throws {
        try validatePriority(entry)
        try validateSignedAmount(entry.monthly, field: "monthly amount")
        try validateSignedAmount(entry.amount, field: "amount")
        try validateSignedAmount(entry.adjustment, field: "adjustment")
        try validatePercentage(entry.percentage)
        try validatePercentage(entry.percent)
        try validateNumMonths(entry.numMonths)
        try validateInterval(entry.period?.amount, field: "period interval")
        try validateLookBack(entry.lookBack)
        try validateRepeatInterval(entry.repeatInterval)
        try validateWeight(entry.weight)

        switch entry.type {
        case "simple":
            guard entry.monthly != nil || entry.limit != nil else {
                throw LocalFirstError.unsupportedTemplate("simple without monthly amount")
            }
            try validateLimit(entry.limit)
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
               BudgetTemplateCalendar.validatedDate(starting) == nil {
                throw LocalFirstError.unsupportedTemplate("periodic start date")
            }
            try validateLimit(entry.limit)
        case "copy":
            // Actual's parser accepts `copy from N months ago` with an optional
            // attached limit and persists that `limit` field, but runCopy() and
            // checkLimit() ignore it. Accept the copy; do not validate or apply
            // the ignored property.
            guard let lookBack = entry.lookBack,
                  Bounds.lookBack.contains(lookBack) else {
                throw LocalFirstError.unsupportedTemplate("copy")
            }
        case "by":
            guard entry.amount != nil,
                  BudgetTemplateCalendar.validMonth(entry.month),
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
            try validateLimit(entry.standaloneLimit)
        case "refill":
            guard entry.limit == nil else {
                throw LocalFirstError.unsupportedTemplate("invalid refill template")
            }
        case "remainder":
            guard entry.weight != nil else {
                throw LocalFirstError.unsupportedTemplate("remainder is missing weight")
            }
            try validateLimit(entry.limit)
        case "average":
            guard let numMonths = entry.numMonths,
                  Bounds.numMonths.contains(numMonths) else {
                throw LocalFirstError.unsupportedTemplate("average")
            }
        case "percentage":
            guard let percent = entry.percentageAmount,
                  Bounds.percentage.contains(percent),
                  let source = entry.sourceCategory?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty else {
                throw LocalFirstError.unsupportedTemplate("percentage")
            }
        case "spend":
            guard entry.amount != nil,
                  BudgetTemplateCalendar.validMonth(entry.month),
                  BudgetTemplateCalendar.validMonth(entry.fromMonth),
                  entry.limit == nil,
                  entry.repeatInterval.map(Bounds.repeatInterval.contains) ?? true else {
                throw LocalFirstError.unsupportedTemplate("invalid spend template")
            }
        case "schedule":
            guard entry.limit == nil else {
                throw LocalFirstError.unsupportedTemplate("schedule")
            }
            guard entry.scheduleLookupKey != nil else {
                throw LocalFirstError.unsupportedTemplate(entry.missingScheduleReason)
            }
        case "goal":
            guard entry.amount != nil else {
                throw LocalFirstError.unsupportedTemplate("goal is missing amount")
            }
        default:
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
    }

    func validateByScheduleAndSpend(
        _ entries: [BudgetTemplateEntry],
        monthValue: Int,
        activeScheduleNames: Set<String>,
        activeScheduleIDs: Set<String> = []
    ) throws {
        let scheduleAndBy = entries.filter { $0.type == "schedule" || $0.type == "by" }
        guard !scheduleAndBy.isEmpty else {
            return
        }

        for entry in entries where entry.type == "schedule" {
            if let scheduleID = entry.presentScheduleID {
                guard activeScheduleIDs.contains(scheduleID) else {
                    throw LocalFirstError.unsupportedTemplate(entry.missingScheduleReason)
                }
            } else if let name = entry.trimmedScheduleName {
                guard activeScheduleNames.contains(name) else {
                    throw LocalFirstError.unsupportedTemplate(entry.missingScheduleReason)
                }
            } else {
                throw LocalFirstError.unsupportedTemplate(entry.missingScheduleReason)
            }
        }

        let priorities = scheduleAndBy.compactMap { $0.priority }
        if let lowest = priorities.min() {
            for entry in scheduleAndBy where entry.priority != lowest {
                throw LocalFirstError.unsupportedTemplate(
                    "Schedule and By templates must be the same priority level. Fix by setting all Schedule and By templates to priority level \(lowest)"
                )
            }
        }

        for entry in entries where entry.type == "by" || entry.type == "spend" {
            guard let month = entry.month,
                  let target = try? BudgetTemplateCalendar.parseMonth(month) else {
                continue
            }
            let distance = try BudgetTemplateCalendar.monthDistance(
                from: monthValue,
                to: target
            )
            if distance < 0, entry.repeatInterval == nil, entry.annual != true {
                throw LocalFirstError.unsupportedTemplate(
                    "Target month has passed, remove or update the target month"
                )
            }
        }
    }

    func validatePercentageSources(
        _ entries: [BudgetTemplateEntry],
        monthSources: BudgetTemplateEngine.MonthSources
    ) throws {
        for entry in entries where entry.type == "percentage" {
            _ = try resolvePercentageSource(entry, monthSources: monthSources)
        }
    }

    func validateOneGoal(_ entries: [BudgetTemplateEntry]) throws {
        let goalCount = entries.filter {
            $0.directive == "goal" && $0.type == "goal"
        }.count
        guard goalCount <= 1 else {
            throw LocalFirstError.unsupportedTemplate(
                "Only one #goal is allowed per category"
            )
        }
    }

    func validateOneSpend(_ entries: [BudgetTemplateEntry]) throws {
        let spendCount = entries.filter { $0.type == "spend" }.count
        guard spendCount <= 1 else {
            throw LocalFirstError.unsupportedTemplate(
                "Only one spend template is allowed per category"
            )
        }
    }

    func validateInteractions(_ entries: [BudgetTemplateEntry]) throws {
        let byPriorities = Set(
            entries.filter { $0.type == "by" }.compactMap(\.priority)
        )
        guard byPriorities.count <= 1 else {
            throw LocalFirstError.unsupportedTemplate(
                "all by templates in a category must use the same priority"
            )
        }

        let limits = entries.filter(Self.hasEffectiveLimit)
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

    func validateLimit(_ limit: BudgetTemplateLimit?) throws {
        guard let limit else {
            return
        }
        guard let amount = limit.amount,
              amount.isFinite,
              Bounds.nonnegativeAmount.contains(amount) else {
            throw LocalFirstError.unsupportedTemplate(
                "up-to limit is missing its amount or period"
            )
        }
        switch limit.period {
        case "monthly":
            guard limit.start == nil || BudgetTemplateCalendar.validatedDate(limit.start!) != nil else {
                throw LocalFirstError.unsupportedTemplate(
                    "monthly up-to limit has an invalid start date"
                )
            }
        case "daily":
            break
        case "weekly":
            guard let start = limit.start,
                  BudgetTemplateCalendar.validatedDate(start) != nil else {
                throw LocalFirstError.unsupportedTemplate(
                    "weekly limit requires a start date (YYYY-MM-DD)"
                )
            }
        default:
            throw LocalFirstError.unsupportedTemplate(
                "only daily, weekly, and monthly up-to limits are supported"
            )
        }
    }

    private func validatePriority(_ entry: BudgetTemplateEntry) throws {
        switch entry.type {
        case "remainder", "limit":
            guard entry.priority == nil else {
                throw LocalFirstError.unsupportedTemplate(
                    "\(entry.type) templates must not have a priority"
                )
            }
        case "simple", "periodic", "copy", "by", "refill", "average", "percentage", "spend", "schedule":
            guard let priority = entry.priority,
                  Bounds.priority.contains(priority) else {
                throw LocalFirstError.unsupportedTemplate(
                    "\(entry.type) templates require a numeric priority"
                )
            }
        case "goal":
            if let priority = entry.priority {
                guard Bounds.priority.contains(priority) else {
                    throw LocalFirstError.unsupportedTemplate(
                        "priority is outside the supported range"
                    )
                }
            }
        default:
            throw LocalFirstError.unsupportedTemplate(entry.type)
        }
    }

    private func validateSignedAmount(_ amount: Double?, field: String) throws {
        guard let amount else {
            return
        }
        guard amount.isFinite, Bounds.signedTemplateAmount.contains(amount) else {
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

    private func validateNumMonths(_ numMonths: Int?) throws {
        guard let numMonths else {
            return
        }
        guard Bounds.numMonths.contains(numMonths) else {
            throw LocalFirstError.unsupportedTemplate(
                "average window is outside the supported range"
            )
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

    private func validateWeight(_ weight: Double?) throws {
        guard let weight else {
            return
        }
        guard weight.isFinite, Bounds.weight.contains(weight) else {
            throw LocalFirstError.unsupportedTemplate("weight is outside the supported range")
        }
    }
}
