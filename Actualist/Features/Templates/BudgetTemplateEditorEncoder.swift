import Foundation

/// Encodes typed editor drafts into Actual's `goal_def` document shape.
enum BudgetTemplateEditorEncoder {
    static func encode(_ drafts: [BudgetTemplateDraft]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(drafts.map(EncodedDraft.init))
        guard let json = String(data: data, encoding: .utf8) else {
            throw BudgetTemplateDefinition.ParseFailure.unreadable
        }
        return json
    }

    private struct EncodedLimit: Encodable {
        let amount: Double
        let hold: Bool
        let period: String
        let start: String?

        private enum CodingKeys: String, CodingKey {
            case amount
            case hold
            case period
            case start
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(amount, forKey: .amount)
            try container.encode(hold, forKey: .hold)
            try container.encode(period, forKey: .period)
            try container.encodeIfPresent(start, forKey: .start)
        }
    }

    private struct EncodedPeriod: Encodable {
        let period: String
        let amount: Int
    }

    private struct EncodedDraft: Encodable {
        let draft: BudgetTemplateDraft

        private enum CodingKeys: String, CodingKey {
            case directive
            case type
            case description
            case priority
            case amount
            case period
            case starting
            case limit
            case lookBack
            case numMonths
            case name
            case scheduleId
            case full
            case adjustment
            case adjustmentType
            case percent
            case previous
            case category
            case month
            case from
            case annual
            case `repeat`
            case hold
            case start
            case weight
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            func encodeDescription(_ description: String?) throws {
                guard let description,
                      !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                try container.encode(description, forKey: .description)
            }
            func encodeAdjustment(_ adjustment: BudgetTemplateAdjustment?) throws {
                guard let adjustment else { return }
                try container.encode(adjustment.value, forKey: .adjustment)
                try container.encode(adjustment.type, forKey: .adjustmentType)
            }
            func encodeLimit(_ limit: BudgetTemplateUpToHold?) throws {
                guard let limit else { return }
                try container.encode(
                    EncodedLimit(
                        amount: limit.amount,
                        hold: limit.hold,
                        period: limit.period,
                        start: limit.start
                    ),
                    forKey: .limit
                )
            }

            switch draft {
            case .monthlyFixed(let value):
                try container.encode("template", forKey: .directive)
                try container.encode("periodic", forKey: .type)
                try container.encode(value.amount, forKey: .amount)
                try container.encode(
                    EncodedPeriod(period: value.cadence.rawValue, amount: value.interval),
                    forKey: .period
                )
                try container.encode(value.starting, forKey: .starting)
                try container.encode(value.priority, forKey: .priority)
                try encodeLimit(value.upTo)
                try encodeDescription(value.description)
            case .dateTarget(let value):
                try container.encode("template", forKey: .directive)
                try container.encode(value.isSpend ? "spend" : "by", forKey: .type)
                try container.encode(value.amount, forKey: .amount)
                try container.encode(value.month, forKey: .month)
                try container.encode(value.priority, forKey: .priority)
                if let repeatInterval = value.repeatInterval {
                    try container.encode(repeatInterval, forKey: .repeat)
                    try container.encode(value.annual, forKey: .annual)
                }
                if let fromMonth = value.fromMonth {
                    try container.encode(fromMonth, forKey: .from)
                }
                try encodeDescription(value.description)
            case .percentage(let value):
                try container.encode("template", forKey: .directive)
                try container.encode("percentage", forKey: .type)
                try container.encode(value.percent, forKey: .percent)
                try container.encode(value.previous, forKey: .previous)
                try container.encode(value.sourceCategory, forKey: .category)
                try container.encode(value.priority, forKey: .priority)
                try encodeDescription(value.description)
            case .balanceLimit(let value):
                try container.encode("template", forKey: .directive)
                try container.encode("limit", forKey: .type)
                try container.encode(value.amount, forKey: .amount)
                try container.encode(value.hold, forKey: .hold)
                try container.encode(value.period.rawValue, forKey: .period)
                try container.encodeNil(forKey: .priority)
                try container.encodeIfPresent(value.start, forKey: .start)
                try encodeDescription(value.description)
            case .refill(let value):
                try container.encode("template", forKey: .directive)
                try container.encode("refill", forKey: .type)
                try container.encode(value.priority, forKey: .priority)
                try encodeDescription(value.description)
            case .copy(let value):
                try container.encode("template", forKey: .directive)
                try container.encode("copy", forKey: .type)
                try container.encode(value.lookBack, forKey: .lookBack)
                try container.encode(value.priority, forKey: .priority)
                try encodeLimit(value.legacyLimit)
                try encodeDescription(value.description)
            case .average(let value):
                try container.encode("template", forKey: .directive)
                try container.encode("average", forKey: .type)
                try container.encode(value.numMonths, forKey: .numMonths)
                try container.encode(value.priority, forKey: .priority)
                try encodeAdjustment(value.adjustment)
                try encodeDescription(value.description)
            case .schedule(let value):
                try container.encode("template", forKey: .directive)
                try container.encode("schedule", forKey: .type)
                if !value.name.isEmpty {
                    try container.encode(value.name, forKey: .name)
                }
                try container.encode(value.priority, forKey: .priority)
                if value.full {
                    try container.encode(true, forKey: .full)
                }
                try container.encodeIfPresent(value.scheduleId, forKey: .scheduleId)
                try encodeAdjustment(value.adjustment)
                try encodeDescription(value.description)
            case .remainder(let value):
                try container.encode("template", forKey: .directive)
                try container.encode("remainder", forKey: .type)
                try container.encode(value.weight, forKey: .weight)
                try container.encodeNil(forKey: .priority)
                try encodeLimit(value.legacyLimit)
                try encodeDescription(value.description)
            case .goal(let value):
                try container.encode("goal", forKey: .directive)
                try container.encode("goal", forKey: .type)
                try container.encode(value.amount, forKey: .amount)
                try container.encodeNil(forKey: .priority)
                try encodeDescription(value.description)
            }
        }
    }
}
