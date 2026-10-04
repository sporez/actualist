import Foundation

// A goal_def entry from Actual's template JSON.
struct BudgetTemplateEntry: Decodable, Equatable, Sendable {
    let type: String
    let directive: String?
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
    let period: BudgetTemplatePeriod?
    let starting: String?
    let lookBack: Int?
    let limit: BudgetTemplateLimit?
    let standaloneLimit: BudgetTemplateLimit?
    let month: String?
    let fromMonth: String?
    let annual: Bool?
    let repeatInterval: Int?
    let weight: Double?
    let name: String?
    let scheduleId: String?
    let full: Bool?

    var percentageAmount: Double? { percent ?? percentage }

    // Actual requires `directive`. Only `template` entries change the budget.
    // `#goal` entries write `goal` / `long_goal` and keep the current budget
    // when they are the only actionable directive.
    var setsBudget: Bool { directive == "template" }
    var isGoal: Bool { directive == "goal" && type == "goal" }

    // Actual prefers immutable `scheduleId` and only uses `name` for older
    // note/template definitions that never stored an ID.
    var presentScheduleID: String? {
        guard let scheduleId, !scheduleId.isEmpty else { return nil }
        return scheduleId
    }

    var trimmedScheduleName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var scheduleLookupKey: String? {
        presentScheduleID ?? trimmedScheduleName
    }

    var missingScheduleReason: String {
        if let id = presentScheduleID {
            return "Schedule \(name ?? id) does not exist"
        }
        if let trimmed = trimmedScheduleName {
            return "Schedule \(trimmed) does not exist"
        }
        return "Schedule template has no scheduleId or name"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case directive
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
        limit = try container.decodeIfPresent(BudgetTemplateLimit.self, forKey: .limit)
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
            standaloneLimit = BudgetTemplateLimit(
                amount: amount,
                period: try container.decodeIfPresent(String.self, forKey: .period),
                hold: try container.decodeIfPresent(Bool.self, forKey: .hold),
                start: try container.decodeIfPresent(String.self, forKey: .start)
            )
        } else {
            period = try container.decodeIfPresent(BudgetTemplatePeriod.self, forKey: .period)
            standaloneLimit = nil
        }
    }
}

struct BudgetTemplatePeriod: Decodable, Equatable, Sendable {
    let amount: Int?
    let period: String?
}

struct BudgetTemplateLimit: Decodable, Equatable, Sendable {
    let amount: Double?
    let period: String?
    let hold: Bool?
    let start: String?
}
