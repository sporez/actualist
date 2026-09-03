import Foundation

/// Encode/decode and Cut A catalog for UI-managed templates.
///
/// Decoding uses the apply engine's `BudgetTemplateEntry`. Encoding writes
/// Actual 26.8.1 `goal_def` JSON. New monthly Fixed is web `periodic`
/// (1 month, starting = first of the current month, default priority 1).
enum BudgetTemplateDefinition {
    static let defaultPriority = 1

    static func firstDayOfCurrentMonth(now: Date) -> String {
        let monthValue = BudgetTemplateCalendar.currentMonthValue(now: now)
        return "\(BudgetTemplateCalendar.monthID(monthValue))-01"
    }

    static func parseEntries(
        from json: String?
    ) -> Result<[BudgetTemplateEntry], ParseFailure> {
        guard let json else {
            return .success([])
        }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return .success([])
        }
        guard let data = trimmed.data(using: .utf8) else {
            return .failure(.unreadable)
        }
        do {
            return .success(try JSONDecoder().decode([BudgetTemplateEntry].self, from: data))
        } catch {
            return .failure(.unreadable)
        }
    }

    /// Cut A drafts for `json`, or `nil` if any entry is outside the catalog.
    static func drafts(fromJSON json: String?, now: Date) -> [BudgetTemplateDraft]? {
        switch parseEntries(from: json) {
        case .failure:
            return nil
        case .success(let entries):
            return drafts(from: entries, now: now)
        }
    }

    static func drafts(
        from entries: [BudgetTemplateEntry],
        now: Date
    ) -> [BudgetTemplateDraft]? {
        var drafts: [BudgetTemplateDraft] = []
        drafts.reserveCapacity(entries.count)
        for entry in entries {
            guard let draft = draft(from: entry, now: now) else {
                return nil
            }
            drafts.append(draft)
        }
        return drafts
    }

    static func encode(_ drafts: [BudgetTemplateDraft]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(drafts.map { EncodedDraft(draft: $0) })
        guard let json = String(data: data, encoding: .utf8) else {
            throw ParseFailure.unreadable
        }
        return json
    }

    static func areCutAEditable(_ entries: [BudgetTemplateEntry]) -> Bool {
        guard entries.count <= BudgetTemplateEngine.Bounds.maximumEntriesPerCategory else {
            return false
        }
        return entries.allSatisfy(isCutAEditable)
    }

    static func isCutAEditable(_ entry: BudgetTemplateEntry) -> Bool {
        let directive = entry.directive?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (directive, entry.type) {
        case ("template", "simple"):
            return isMonthlySimple(entry)
        case ("template", "periodic"):
            return isMonthlyPeriodic(entry)
        case ("template", "copy"):
            return isCopy(entry)
        case ("template", "average"):
            return isAverage(entry)
        case ("template", "schedule"):
            return isSchedule(entry)
        case ("template", "remainder"):
            return isRemainder(entry)
        case ("goal", "goal"):
            return isGoal(entry)
        default:
            return false
        }
    }

    enum ParseFailure: Error, Equatable {
        case unreadable
    }
}

extension BudgetTemplateDefinition {
    static func draft(from entry: BudgetTemplateEntry, now: Date) -> BudgetTemplateDraft? {
        guard isCutAEditable(entry) else {
            return nil
        }
        switch entry.type {
        case "simple":
            return .monthlyFixed(
                amount: entry.monthly ?? 0,
                priority: entry.priority ?? defaultPriority,
                now: now,
                upTo: upToHold(from: entry.limit)
            )
        case "periodic":
            let starting = entry.starting?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedStarting: String
            if let starting, !starting.isEmpty {
                resolvedStarting = starting
            } else {
                resolvedStarting = firstDayOfCurrentMonth(now: now)
            }
            return .monthlyFixed(
                BudgetTemplateDraft.MonthlyFixed(
                    amount: entry.amount ?? 0,
                    priority: entry.priority ?? defaultPriority,
                    starting: resolvedStarting,
                    upTo: upToHold(from: entry.limit)
                )
            )
        case "copy":
            return .copy(
                lookBack: entry.lookBack ?? 1,
                priority: entry.priority ?? defaultPriority
            )
        case "average":
            return .average(
                numMonths: entry.numMonths ?? 3,
                priority: entry.priority ?? defaultPriority
            )
        case "schedule":
            return .schedule(
                name: entry.trimmedScheduleName ?? "",
                scheduleId: entry.presentScheduleID,
                priority: entry.priority ?? defaultPriority
            )
        case "remainder":
            return .remainder(weight: entry.weight ?? 1)
        case "goal":
            return .goal(amount: entry.amount ?? 0)
        default:
            return nil
        }
    }

    private static func isMonthlySimple(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              isSignedAmount(entry.monthly),
              isSupportedLimit(entry.limit),
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else {
            return false
        }
        return true
    }

    private static func isMonthlyPeriodic(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              isSignedAmount(entry.amount),
              entry.period?.period == "month",
              entry.period?.amount == 1,
              isSupportedStarting(entry.starting),
              isSupportedLimit(entry.limit),
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else {
            return false
        }
        return true
    }

    private static func isCopy(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              let lookBack = entry.lookBack,
              BudgetTemplateEngine.Bounds.lookBack.contains(lookBack),
              entry.limit == nil,
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else {
            return false
        }
        return true
    }

    private static func isAverage(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              let numMonths = entry.numMonths,
              BudgetTemplateEngine.Bounds.numMonths.contains(numMonths),
              entry.limit == nil,
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else {
            return false
        }
        return true
    }

    private static func isSchedule(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              entry.scheduleLookupKey != nil,
              entry.limit == nil,
              entry.full != true,
              entry.adjustment == nil,
              entry.adjustmentType == nil else {
            return false
        }
        return true
    }

    private static func isRemainder(_ entry: BudgetTemplateEntry) -> Bool {
        guard entry.priority == nil,
              let weight = entry.weight,
              weight.isFinite,
              BudgetTemplateEngine.Bounds.weight.contains(weight),
              entry.limit == nil,
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else {
            return false
        }
        return true
    }

    private static func isGoal(_ entry: BudgetTemplateEntry) -> Bool {
        guard isSignedAmount(entry.amount),
              entry.limit == nil,
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else {
            return false
        }
        if let priority = entry.priority {
            return BudgetTemplateEngine.Bounds.priority.contains(priority)
        }
        return true
    }

    private static func hasPriority(_ entry: BudgetTemplateEntry) -> Bool {
        guard let priority = entry.priority else {
            return false
        }
        return BudgetTemplateEngine.Bounds.priority.contains(priority)
    }

    private static func isSignedAmount(_ amount: Double?) -> Bool {
        guard let amount, amount.isFinite else {
            return false
        }
        return BudgetTemplateEngine.Bounds.signedTemplateAmount.contains(amount)
    }

    private static func isSupportedStarting(_ starting: String?) -> Bool {
        guard let starting else {
            return true
        }
        let trimmed = starting.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        return BudgetTemplateCalendar.validatedDate(trimmed) != nil
    }

    private static func isSupportedLimit(_ limit: BudgetTemplateLimit?) -> Bool {
        guard let limit else {
            return true
        }
        guard let amount = limit.amount,
              amount.isFinite,
              BudgetTemplateEngine.Bounds.nonnegativeAmount.contains(amount) else {
            return false
        }
        switch limit.period {
        case "monthly":
            return limit.start == nil
        case "daily":
            return true
        case "weekly":
            guard let start = limit.start,
                  BudgetTemplateCalendar.validatedDate(start) != nil else {
                return false
            }
            return true
        default:
            return false
        }
    }

    private static func upToHold(from limit: BudgetTemplateLimit?) -> BudgetTemplateUpToHold? {
        guard let limit, let amount = limit.amount, let period = limit.period else {
            return nil
        }
        return BudgetTemplateUpToHold(
            amount: amount,
            hold: limit.hold ?? false,
            period: period,
            start: limit.start
        )
    }
}

private struct EncodedDraft: Encodable {
    var draft: BudgetTemplateDraft

    private enum CodingKeys: String, CodingKey {
        case directive
        case type
        case priority
        case amount
        case period
        case starting
        case limit
        case lookBack
        case numMonths
        case name
        case scheduleId
        case weight
    }

    private struct Period: Encodable {
        var period: String
        var amount: Int
    }

    private struct Limit: Encodable {
        var amount: Double
        var hold: Bool
        var period: String
        var start: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(amount, forKey: .amount)
            try container.encode(hold, forKey: .hold)
            try container.encode(period, forKey: .period)
            try container.encodeIfPresent(start, forKey: .start)
        }

        private enum CodingKeys: String, CodingKey {
            case amount
            case hold
            case period
            case start
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch draft {
        case .monthlyFixed(let value):
            try container.encode("template", forKey: .directive)
            try container.encode("periodic", forKey: .type)
            try container.encode(value.amount, forKey: .amount)
            try container.encode(Period(period: "month", amount: 1), forKey: .period)
            try container.encode(value.starting, forKey: .starting)
            try container.encode(value.priority, forKey: .priority)
            if let upTo = value.upTo {
                try container.encode(
                    Limit(
                        amount: upTo.amount,
                        hold: upTo.hold,
                        period: upTo.period,
                        start: upTo.start
                    ),
                    forKey: .limit
                )
            }
        case .copy(let value):
            try container.encode("template", forKey: .directive)
            try container.encode("copy", forKey: .type)
            try container.encode(value.lookBack, forKey: .lookBack)
            try container.encode(value.priority, forKey: .priority)
        case .average(let value):
            try container.encode("template", forKey: .directive)
            try container.encode("average", forKey: .type)
            try container.encode(value.numMonths, forKey: .numMonths)
            try container.encode(value.priority, forKey: .priority)
        case .schedule(let value):
            try container.encode("template", forKey: .directive)
            try container.encode("schedule", forKey: .type)
            try container.encode(value.name, forKey: .name)
            try container.encode(value.priority, forKey: .priority)
            if let scheduleId = value.scheduleId, !scheduleId.isEmpty {
                try container.encode(scheduleId, forKey: .scheduleId)
            }
        case .remainder(let value):
            try container.encode("template", forKey: .directive)
            try container.encode("remainder", forKey: .type)
            try container.encode(value.weight, forKey: .weight)
            try container.encodeNil(forKey: .priority)
        case .goal(let value):
            try container.encode("goal", forKey: .directive)
            try container.encode("goal", forKey: .type)
            try container.encode(value.amount, forKey: .amount)
            try container.encodeNil(forKey: .priority)
        }
    }
}
