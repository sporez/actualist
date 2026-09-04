import Foundation

/// The editor's loss-aware JSON boundary. `BudgetTemplateEntry` is intentionally
/// not used here because its apply-focused shape omits authoring metadata.
enum BudgetTemplateEditorCodec {
    /// Decodes the normalized authoring catalog. Legacy fixed/simple nested
    /// limits become standalone Limit drafts before the editor sees them.
    static func decodeEditor(
        json: String?,
        now: Date
    ) -> Result<[BudgetTemplateDraft]?, BudgetTemplateDefinition.ParseFailure> {
        do {
            let entries = try rawEntries(from: json)
            let drafts = try decodeNormalized(json: json, now: now)
            guard entries.isEmpty || !drafts.isEmpty,
                  drafts.allSatisfy(isEditorReady) else {
                return .success(nil)
            }
            return .success(drafts)
        } catch let failure as BudgetTemplateDefinition.ParseFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreadable)
        }
    }

    static func decodeNormalized(
        json: String?,
        now: Date
    ) throws -> [BudgetTemplateDraft] {
        let entries = try rawEntries(from: json)
        var drafts: [BudgetTemplateDraft] = []
        for entry in entries {
            drafts.append(contentsOf: try normalizedDrafts(from: entry, now: now))
        }
        guard drafts.count <= BudgetTemplateEngine.Bounds.maximumEntriesPerCategory else {
            throw BudgetTemplateDefinition.ParseFailure.unsupportedType("too many template entries")
        }
        return drafts
    }

    static func encode(_ drafts: [BudgetTemplateDraft]) throws -> String {
        try BudgetTemplateEditorEncoder.encode(drafts)
    }
}

extension BudgetTemplateEditorCodec {
    static func isEditorReady(_ draft: BudgetTemplateDraft) -> Bool {
        // Representability is distinct from validity. Known, finite values can
        // open for repair; the shared authoring validator gates every save.
        switch draft {
        case .monthlyFixed(let value): return value.amount.isFinite
        case .dateTarget(let value): return value.amount.isFinite
        case .percentage(let value): return value.percent.isFinite
        case .balanceLimit(let value): return value.amount.isFinite
        case .refill, .copy: return true
        case .average(let value): return value.adjustment.map { $0.value.isFinite } ?? true
        case .schedule(let value): return value.adjustment.map { $0.value.isFinite } ?? true
        case .remainder(let value): return value.weight.isFinite && value.legacyLimit == nil
        case .goal(let value): return value.amount.isFinite
        }
    }
}

private extension BudgetTemplateEditorCodec {
    struct RawPeriod: Decodable {
        let period: String?
        let amount: Int?
    }

    struct RawLimit: Decodable {
        let amount: Double?
        let hold: Bool?
        let period: String?
        let start: String?
    }

    struct RawEntry: Decodable {
        let type: String
        let directive: String?
        let description: String?
        let priority: Int?
        let monthly: Double?
        let amount: Double?
        let percentage: Double?
        let percent: Double?
        let previous: Bool?
        let sourceCategory: String?
        let numMonths: Int?
        let adjustment: Double?
        let adjustmentType: String?
        let period: RawPeriod?
        let limitPeriod: String?
        let starting: String?
        let lookBack: Int?
        let limit: RawLimit?
        let month: String?
        let fromMonth: String?
        let annual: Bool?
        let repeatInterval: Int?
        let weight: Double?
        let name: String?
        let scheduleId: String?
        let full: Bool?
        let limitAmount: Double?
        let limitHold: Bool?
        let limitStart: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case directive
            case description
            case priority
            case monthly
            case amount
            case percentage
            case percent
            case previous
            case sourceCategory = "category"
            case numMonths
            case adjustment
            case adjustmentType
            case period
            case starting
            case lookBack
            case limit
            case hold
            case start
            case month
            case fromMonth = "from"
            case annual
            case repeatInterval = "repeat"
            case weight
            case name
            case scheduleId
            case full
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            directive = try container.decodeIfPresent(String.self, forKey: .directive)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            priority = try container.decodeIfPresent(Int.self, forKey: .priority)
            monthly = try container.decodeIfPresent(Double.self, forKey: .monthly)
            amount = try container.decodeIfPresent(Double.self, forKey: .amount)
            percentage = try container.decodeIfPresent(Double.self, forKey: .percentage)
            percent = try container.decodeIfPresent(Double.self, forKey: .percent)
            previous = try container.decodeIfPresent(Bool.self, forKey: .previous)
            sourceCategory = try container.decodeIfPresent(String.self, forKey: .sourceCategory)
            numMonths = try container.decodeIfPresent(Int.self, forKey: .numMonths)
            adjustment = try container.decodeIfPresent(Double.self, forKey: .adjustment)
            adjustmentType = try container.decodeIfPresent(String.self, forKey: .adjustmentType)
            starting = try container.decodeIfPresent(String.self, forKey: .starting)
            lookBack = try container.decodeIfPresent(Int.self, forKey: .lookBack)
            limit = try container.decodeIfPresent(RawLimit.self, forKey: .limit)
            month = try container.decodeIfPresent(String.self, forKey: .month)
            fromMonth = try container.decodeIfPresent(String.self, forKey: .fromMonth)
            annual = try container.decodeIfPresent(Bool.self, forKey: .annual)
            repeatInterval = try container.decodeIfPresent(Int.self, forKey: .repeatInterval)
            weight = try container.decodeIfPresent(Double.self, forKey: .weight)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            scheduleId = try container.decodeIfPresent(String.self, forKey: .scheduleId)
            full = try container.decodeIfPresent(Bool.self, forKey: .full)

            if type == "limit" {
                period = nil
                limitPeriod = try container.decodeIfPresent(String.self, forKey: .period)
                limitAmount = amount
                limitHold = try container.decodeIfPresent(Bool.self, forKey: .hold)
                limitStart = try container.decodeIfPresent(String.self, forKey: .start)
            } else {
                limitPeriod = nil
                limitAmount = nil
                limitHold = nil
                limitStart = nil
                period = try container.decodeIfPresent(RawPeriod.self, forKey: .period)
            }
        }

        var editorLimit: BudgetTemplateUpToHold? {
            if let limit {
                guard let amount = limit.amount, let period = limit.period else {
                    return nil
                }
                return BudgetTemplateUpToHold(
                    amount: amount,
                    hold: limit.hold ?? false,
                    period: period,
                    start: limit.start
                )
            }
            guard let limitAmount, let limitPeriod else { return nil }
            return BudgetTemplateUpToHold(
                amount: limitAmount,
                hold: limitHold ?? false,
                period: limitPeriod,
                start: limitStart
            )
        }

        var normalizedDescription: String? {
            guard let description,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return description
        }
    }

    static let commonKeys: Set<String> = ["directive", "type", "description"]

    static let allowedKeysByType: [String: Set<String>] = [
        "simple": commonKeys.union(["monthly", "priority", "limit"]),
        "periodic": commonKeys.union(["amount", "period", "starting", "priority", "limit"]),
        "by": commonKeys.union(["amount", "month", "annual", "repeat", "from", "priority"]),
        "spend": commonKeys.union(["amount", "month", "annual", "repeat", "from", "priority"]),
        "percentage": commonKeys.union(["percent", "percentage", "previous", "category", "priority"]),
        "limit": commonKeys.union(["amount", "period", "hold", "start", "priority"]),
        "refill": commonKeys.union(["priority"]),
        "schedule": commonKeys.union(["name", "scheduleId", "full", "adjustment", "adjustmentType", "priority"]),
        "average": commonKeys.union(["numMonths", "adjustment", "adjustmentType", "priority"]),
        "copy": commonKeys.union(["lookBack", "priority", "limit"]),
        "remainder": commonKeys.union(["weight", "limit", "priority"]),
        "goal": commonKeys.union(["amount", "priority"])
    ]

    static func rawEntries(from json: String?) throws -> [RawEntry] {
        guard let json else { return [] }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return [] }
        guard let data = trimmed.data(using: .utf8) else {
            throw BudgetTemplateDefinition.ParseFailure.unreadable
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BudgetTemplateDefinition.ParseFailure.unreadable
        }
        guard let dictionaries = object as? [[String: Any]] else {
            throw BudgetTemplateDefinition.ParseFailure.unreadable
        }
        for dictionary in dictionaries {
            guard let type = dictionary["type"] as? String,
                  let allowed = allowedKeysByType[type] else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType("unknown template type")
            }
            if let unknown = Set(dictionary.keys).subtracting(allowed).sorted().first {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedField(
                    type + "." + unknown
                )
            }
            try validateNestedLimit(dictionary["limit"], type: type)
            if type != "limit" {
                try validateNestedPeriod(dictionary["period"], type: type)
            }
        }
        do {
            let entries = try JSONDecoder().decode([RawEntry].self, from: data)
            for entry in entries {
                if let limit = entry.limit,
                   limit.amount == nil || limit.period == nil {
                    throw BudgetTemplateDefinition.ParseFailure.unsupportedType(
                        entry.type + " limit"
                    )
                }
                if let period = entry.period,
                   period.period == nil || period.amount == nil {
                    throw BudgetTemplateDefinition.ParseFailure.unsupportedType(
                        entry.type + " period"
                    )
                }
            }
            return entries
        } catch let failure as BudgetTemplateDefinition.ParseFailure {
            throw failure
        } catch {
            throw BudgetTemplateDefinition.ParseFailure.unreadable
        }
    }

    static func validateNestedLimit(_ value: Any?, type: String) throws {
        guard let value, !(value is NSNull) else { return }
        guard let dictionary = value as? [String: Any] else {
            throw BudgetTemplateDefinition.ParseFailure.unreadable
        }
        let allowed = Set(["amount", "hold", "period", "start"])
        if let unknown = Set(dictionary.keys).subtracting(allowed).sorted().first {
            throw BudgetTemplateDefinition.ParseFailure.unsupportedField(
                type + ".limit." + unknown
            )
        }
    }

    static func validateNestedPeriod(_ value: Any?, type: String) throws {
        guard let value, !(value is NSNull) else { return }
        guard let dictionary = value as? [String: Any] else {
            throw BudgetTemplateDefinition.ParseFailure.unreadable
        }
        let allowed = Set(["amount", "period"])
        if let unknown = Set(dictionary.keys).subtracting(allowed).sorted().first {
            throw BudgetTemplateDefinition.ParseFailure.unsupportedField(
                type + ".period." + unknown
            )
        }
    }

    static func normalizedDrafts(from entry: RawEntry, now: Date) throws -> [BudgetTemplateDraft] {
        guard let directive = entry.directive?.trimmingCharacters(in: .whitespacesAndNewlines),
              (entry.type == "goal" && directive == "goal"
                || entry.type != "goal" && directive == "template") else {
            throw BudgetTemplateDefinition.ParseFailure.unsupportedType("unsupported template directive")
        }
        switch entry.type {
        case "simple":
            var result: [BudgetTemplateDraft] = []
            let hasMonthly = entry.monthly.map { $0 != 0 } ?? false
            if let limit = try requiredOrNilLimit(entry.editorLimit, type: entry.type) {
                result.append(.balanceLimit(
                    amount: limit.amount,
                    hold: limit.hold,
                    period: try limitPeriod(limit.period),
                    start: limit.start,
                    description: hasMonthly ? nil : entry.normalizedDescription
                ))
                if entry.monthly == nil {
                    result.append(.refill(priority: try requiredPriority(entry.priority, type: entry.type)))
                }
            }
            if let monthly = entry.monthly, hasMonthly || entry.limit == nil {
                result.append(.monthlyFixed(
                    amount: monthly,
                    priority: try requiredPriority(entry.priority, type: entry.type),
                    now: now,
                    description: entry.normalizedDescription
                ))
            }
            return result
        case "periodic":
            guard let amount = entry.amount, let period = entry.period,
                  let cadence = period.period.flatMap(BudgetTemplateCadence.init(rawValue:)),
                  let interval = period.amount else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType("periodic")
            }
            let base = BudgetTemplateDraft.MonthlyFixed(
                amount: amount,
                priority: try requiredPriority(entry.priority, type: entry.type),
                starting: entry.starting.flatMap { $0.isEmpty ? nil : $0 }
                    ?? BudgetTemplateDefinition.firstDayOfCurrentMonth(now: now),
                cadence: cadence,
                interval: interval,
                description: entry.normalizedDescription
            )
            return try baseAndLimit(base: .monthlyFixed(base), limit: entry.editorLimit)
        case "by", "spend":
            guard let amount = entry.amount else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType(
                    "invalid " + entry.type + " template"
                )
            }
            let month = entry.month ?? ""
            let repeatInterval = entry.repeatInterval ?? (entry.annual == nil ? nil : 1)
            return [
                .dateTarget(
                    BudgetTemplateDraft.DateTarget(
                        amount: amount,
                        month: month,
                        priority: try requiredPriority(entry.priority, type: entry.type),
                        repeatInterval: repeatInterval,
                        annual: entry.annual ?? false,
                        fromMonth: entry.fromMonth,
                        isSpend: entry.type == "spend",
                        description: entry.normalizedDescription
                    )
                )
            ]
        case "percentage":
            guard let percent = entry.percent ?? entry.percentage,
                  let priority = entry.priority else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType("percentage")
            }
            return [.percentage(.init(
                percent: percent,
                sourceCategory: entry.sourceCategory ?? "",
                previous: entry.previous ?? false,
                priority: priority,
                description: entry.normalizedDescription
            ))]
        case "limit":
            guard let amount = entry.limitAmount,
                  let period = entry.limitPeriod else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType("limit")
            }
            return [.balanceLimit(.init(
                amount: amount,
                hold: entry.limitHold ?? false,
                period: try limitPeriod(period),
                start: entry.limitStart,
                description: entry.normalizedDescription
            ))]
        case "refill":
            return [.refill(priority: try requiredPriority(entry.priority, type: entry.type), description: entry.normalizedDescription)]
        case "copy":
            guard let lookBack = entry.lookBack else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType("copy")
            }
            return [.copy(
                lookBack: lookBack,
                priority: try requiredPriority(entry.priority, type: entry.type),
                legacyLimit: try requiredOrNilLimit(entry.editorLimit, type: entry.type),
                description: entry.normalizedDescription
            )]
        case "average":
            guard let numMonths = entry.numMonths else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType("average")
            }
            return [.average(
                numMonths: numMonths,
                priority: try requiredPriority(entry.priority, type: entry.type),
                adjustment: try adjustment(value: entry.adjustment, type: entry.adjustmentType),
                description: entry.normalizedDescription
            )]
        case "schedule":
            return [.schedule(
                name: entry.name ?? "",
                scheduleId: entry.presentScheduleID,
                priority: try requiredPriority(entry.priority, type: entry.type),
                full: entry.full ?? false,
                adjustment: try adjustment(value: entry.adjustment, type: entry.adjustmentType),
                description: entry.normalizedDescription
            )]
        case "remainder":
            guard let weight = entry.weight else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType("remainder")
            }
            let base = BudgetTemplateDraft.remainder(weight: weight, description: entry.normalizedDescription)
            return try baseAndLimit(base: base, limit: entry.editorLimit)
        case "goal":
            guard let amount = entry.amount else {
                throw BudgetTemplateDefinition.ParseFailure.unsupportedType("goal")
            }
            return [.goal(amount: amount, description: entry.normalizedDescription)]
        default:
            throw BudgetTemplateDefinition.ParseFailure.unsupportedType(entry.type)
        }
    }

    static func baseAndLimit(
        base: BudgetTemplateDraft,
        limit rawLimit: BudgetTemplateUpToHold?
    ) throws -> [BudgetTemplateDraft] {
        guard let rawLimit else { return [base] }
        let limit = try requiredOrNilLimit(rawLimit, type: "limit")!
        return [
            base,
            .balanceLimit(
                amount: limit.amount,
                hold: limit.hold,
                period: try limitPeriod(limit.period),
                start: limit.start
            )
        ]
    }

    static func adjustment(value: Double?, type: String?) throws -> BudgetTemplateAdjustment? {
        switch (value, type) {
        case (nil, nil):
            return nil
        case (let value?, "fixed"):
            return .fixed(value)
        case (let value?, "percent"):
            return .percent(value)
        default:
            throw BudgetTemplateDefinition.ParseFailure.unsupportedType("adjustment")
        }
    }

    static func requiredPriority(_ priority: Int?, type: String) throws -> Int {
        guard let priority else {
            throw BudgetTemplateDefinition.ParseFailure.unsupportedType(
                type + " requires a priority"
            )
        }
        return priority
    }

    static func requiredOrNilLimit(
        _ limit: BudgetTemplateUpToHold?,
        type: String
    ) throws -> BudgetTemplateUpToHold? {
        guard let limit else { return nil }
        guard limit.amount.isFinite,
              BudgetTemplateLimitPeriod(rawValue: limit.period) != nil else {
            throw BudgetTemplateDefinition.ParseFailure.unsupportedType(type + " limit")
        }
        return limit
    }

    static func limitPeriod(_ period: String) throws -> BudgetTemplateLimitPeriod {
        guard let result = BudgetTemplateLimitPeriod(rawValue: period) else {
            throw BudgetTemplateDefinition.ParseFailure.unsupportedType("limit period")
        }
        return result
    }

}

private extension BudgetTemplateEditorCodec.RawEntry {
    var presentScheduleID: String? {
        guard let scheduleId, !scheduleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return scheduleId
    }

}
