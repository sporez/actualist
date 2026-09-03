import Foundation

/// Shared definition facade for the editor and the local-first apply path.
///
/// The apply path decodes `BudgetTemplateEntry`, while the editor uses its own
/// strict codec so authoring metadata and unknown-field safety are not lost at
/// the boundary.
enum BudgetTemplateDefinition {
    static let defaultPriority = 1

    static func firstDayOfCurrentMonth(now: Date) -> String {
        let monthValue = BudgetTemplateCalendar.currentMonthValue(now: now)
        return "\(BudgetTemplateCalendar.monthID(monthValue))-01"
    }

    static func parseEntries(
        from json: String?
    ) -> Result<[BudgetTemplateEntry], ParseFailure> {
        guard let json else { return .success([]) }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return .success([]) }
        guard let data = trimmed.data(using: .utf8) else {
            return .failure(.unreadable)
        }
        do {
            return .success(try JSONDecoder().decode([BudgetTemplateEntry].self, from: data))
        } catch {
            return .failure(.unreadable)
        }
    }

    /// Cut A-compatible editor drafts. Strictly decodes known fields first;
    /// `nil` means the whole definition must remain view-only.
    static func drafts(fromJSON json: String?, now: Date) -> [BudgetTemplateDraft]? {
        switch BudgetTemplateEditorCodec.decodeCutA(json: json, now: now) {
        case .failure, .success(nil): return nil
        case .success(let drafts?): return drafts
        }
    }

    /// Apply-preview drafts do not need authoring metadata, so this overload
    /// intentionally accepts the engine's calculation entries.
    static func drafts(
        from entries: [BudgetTemplateEntry],
        now: Date
    ) -> [BudgetTemplateDraft]? {
        var drafts: [BudgetTemplateDraft] = []
        drafts.reserveCapacity(entries.count)
        for entry in entries {
            guard let draft = draft(from: entry, now: now) else { return nil }
            drafts.append(draft)
        }
        return drafts
    }

    static func encode(_ drafts: [BudgetTemplateDraft]) throws -> String {
        try BudgetTemplateEditorCodec.encode(drafts)
    }

    /// Strictly decode the complete pinned Actual catalog. This is used by
    /// fixtures and later form phases; Cut A's editor gate remains separate.
    static func normalizedDrafts(fromJSON json: String?, now: Date) throws -> [BudgetTemplateDraft] {
        try BudgetTemplateEditorCodec.decodeNormalized(json: json, now: now)
    }

    static func isEditorEditableJSON(_ json: String?, now: Date = Date()) -> Bool {
        switch BudgetTemplateEditorCodec.decodeCutA(json: json, now: now) {
        case .success(let drafts?):
            return drafts.count <= BudgetTemplateEngine.Bounds.maximumEntriesPerCategory
                && drafts.allSatisfy(\.isComplete)
        case .success(nil), .failure:
            return false
        }
    }

    static func areEditorEditable(_ entries: [BudgetTemplateEntry]) -> Bool {
        guard entries.count <= BudgetTemplateEngine.Bounds.maximumEntriesPerCategory else {
            return false
        }
        return entries.allSatisfy(isEditorEditable)
    }

    static func isEditorEditable(_ entry: BudgetTemplateEntry) -> Bool {
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
        case unsupportedField(String)
        case unsupportedType(String)
    }
}

private extension BudgetTemplateDefinition {
    static func draft(from entry: BudgetTemplateEntry, now: Date) -> BudgetTemplateDraft? {
        guard isEditorEditable(entry) else { return nil }
        switch entry.type {
        case "simple":
            return .monthlyFixed(
                amount: entry.monthly ?? 0,
                priority: entry.priority ?? defaultPriority,
                now: now,
                upTo: upToHold(from: entry.limit)
            )
        case "periodic":
            let starting = entry.starting?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .monthlyFixed(
                BudgetTemplateDraft.MonthlyFixed(
                    amount: entry.amount ?? 0,
                    priority: entry.priority ?? defaultPriority,
                    starting: starting.flatMap { $0.isEmpty ? nil : $0 }
                        ?? firstDayOfCurrentMonth(now: now),
                    upTo: upToHold(from: entry.limit)
                )
            )
        case "copy":
            return .copy(
                lookBack: entry.lookBack ?? 1,
                priority: entry.priority ?? defaultPriority,
                legacyLimit: upToHold(from: entry.limit)
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

    static func isMonthlySimple(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              isSignedAmount(entry.monthly),
              isSupportedLimit(entry.limit),
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else { return false }
        return true
    }

    static func isMonthlyPeriodic(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              isSignedAmount(entry.amount),
              entry.period?.period == "month",
              entry.period?.amount == 1,
              isSupportedStarting(entry.starting),
              isSupportedLimit(entry.limit),
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else { return false }
        return true
    }

    static func isCopy(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              let lookBack = entry.lookBack,
              BudgetTemplateEngine.Bounds.lookBack.contains(lookBack),
              isSupportedLimit(entry.limit),
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else { return false }
        return true
    }

    static func isAverage(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              let numMonths = entry.numMonths,
              BudgetTemplateEngine.Bounds.numMonths.contains(numMonths),
              entry.limit == nil,
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else { return false }
        return true
    }

    static func isSchedule(_ entry: BudgetTemplateEntry) -> Bool {
        guard hasPriority(entry),
              entry.scheduleLookupKey != nil,
              entry.limit == nil,
              entry.full != true,
              entry.adjustment == nil,
              entry.adjustmentType == nil else { return false }
        return true
    }

    static func isRemainder(_ entry: BudgetTemplateEntry) -> Bool {
        guard entry.priority == nil,
              let weight = entry.weight,
              weight.isFinite,
              BudgetTemplateEngine.Bounds.weight.contains(weight),
              entry.limit == nil,
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else { return false }
        return true
    }

    static func isGoal(_ entry: BudgetTemplateEntry) -> Bool {
        guard isSignedAmount(entry.amount),
              entry.limit == nil,
              entry.adjustment == nil,
              entry.adjustmentType == nil,
              entry.full != true else { return false }
        if let priority = entry.priority {
            return BudgetTemplateEngine.Bounds.priority.contains(priority)
        }
        return true
    }

    static func hasPriority(_ entry: BudgetTemplateEntry) -> Bool {
        guard let priority = entry.priority else { return false }
        return BudgetTemplateEngine.Bounds.priority.contains(priority)
    }

    static func isSignedAmount(_ amount: Double?) -> Bool {
        guard let amount, amount.isFinite else { return false }
        return BudgetTemplateEngine.Bounds.signedTemplateAmount.contains(amount)
    }

    static func isSupportedStarting(_ starting: String?) -> Bool {
        guard let starting else { return true }
        let trimmed = starting.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || BudgetTemplateCalendar.validatedDate(trimmed) != nil
    }

    static func isSupportedLimit(_ limit: BudgetTemplateLimit?) -> Bool {
        guard let limit else { return true }
        guard let amount = limit.amount,
              amount.isFinite,
              BudgetTemplateEngine.Bounds.nonnegativeAmount.contains(amount) else {
            return false
        }
        switch limit.period {
        case "monthly":
            // Actual keeps a weekly anchor when cadence changes to monthly;
            // checkLimit ignores it in monthly mode.
            return limit.start == nil || BudgetTemplateCalendar.validatedDate(limit.start!) != nil
        case "daily":
            return true
        case "weekly":
            guard let start = limit.start,
                  BudgetTemplateCalendar.validatedDate(start) != nil else { return false }
            return true
        default:
            return false
        }
    }

    static func upToHold(from limit: BudgetTemplateLimit?) -> BudgetTemplateUpToHold? {
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
