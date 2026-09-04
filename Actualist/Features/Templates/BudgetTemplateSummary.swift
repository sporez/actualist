import Foundation

/// Compact trailing summary for the category-details row and Settings browser.
///
/// Example: `$400.00/mo · Remainder`. Privacy mode randomizes amounts only.
enum BudgetTemplateSummary {
    static func line(
        drafts: [BudgetTemplateDraft],
        currency: BudgetCurrency,
        randomized: Bool,
        seed: String
    ) -> String {
        drafts.enumerated().compactMap { index, draft in
            label(
                draft,
                currency: currency,
                randomized: randomized,
                seed: "\(seed)-\(index)"
            )
        }
        .joined(separator: " · ")
    }

    static func label(
        _ draft: BudgetTemplateDraft,
        currency: BudgetCurrency,
        randomized: Bool,
        seed: String
    ) -> String? {
        switch draft {
        case .monthlyFixed(let value):
            let amount = formattedAmount(
                value.amount,
                currency: currency,
                randomized: randomized,
                seed: seed
            )
            let unit: String
            switch value.cadence {
            case .day: unit = "day"
            case .week: unit = "week"
            case .month: unit = "mo"
            case .year: unit = "year"
            }
            if value.interval == 1 {
                return "\(amount)/\(unit)"
            }
            return "\(amount)/\(value.interval) \(unit)s"
        case .dateTarget(let value):
            return value.isSpend ? "Save by \(value.month) with early spending" : "Save by \(value.month)"
        case .percentage(let value):
            return "\(value.percent)% of \(value.sourceCategory)"
        case .balanceLimit(let value):
            let amount = formattedAmount(
                value.amount,
                currency: currency,
                randomized: randomized,
                seed: seed
            )
            let cadence: String
            switch value.period {
            case .daily: cadence = "day"
            case .weekly: cadence = "week"
            case .monthly: cadence = "month"
            }
            return value.hold ? "Limit \(amount)/\(cadence) hold" : "Limit \(amount)/\(cadence)"
        case .refill:
            return "Refill"
        case .copy(let value):
            if value.lookBack == 1 {
                return "Copy last month"
            }
            return "Copy \(value.lookBack) months ago"
        case .average(let value):
            return "\(value.numMonths)-month average\(adjustmentSummary(value.adjustment, currency: currency, randomized: randomized, seed: seed))"
        case .schedule(let value):
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = value.full ? "Cover" : "Save up for"
            let base = name.isEmpty ? "\(mode) schedule" : "\(mode) \(name)"
            return base + adjustmentSummary(
                value.adjustment,
                currency: currency,
                randomized: randomized,
                seed: seed
            )
        case .remainder:
            return "Remainder"
        case .goal(let value):
            let amount = formattedAmount(
                value.amount,
                currency: currency,
                randomized: randomized,
                seed: seed
            )
            return "Goal \(amount)"
        }
    }

    private static func adjustmentSummary(
        _ adjustment: BudgetTemplateAdjustment?,
        currency: BudgetCurrency,
        randomized: Bool,
        seed: String
    ) -> String {
        guard let adjustment else { return "" }
        let direction = adjustment.value < 0 ? "decreased by" : "increased by"
        switch adjustment {
        case .fixed(let value):
            let amount = formattedAmount(
                abs(value),
                currency: currency,
                randomized: randomized,
                seed: "\(seed)-adjustment"
            )
            return " (\(direction) \(amount))"
        case .percent(let value):
            return " (\(direction) \(formattedNumber(abs(value)))%)"
        }
    }

    private static func formattedNumber(_ value: Double) -> String {
        if value.rounded() == value, let integer = Int(exactly: value) {
            return String(integer)
        }
        return String(value)
    }

    private static func formattedAmount(
        _ display: Double,
        currency: BudgetCurrency,
        randomized: Bool,
        seed: String
    ) -> String {
        let minor = currency.minorUnits(fromDisplay: display) ?? 0
        if randomized {
            return PrivacyDisplay.money(minor, seed: seed, currency: currency)
        }
        return currency.formatted(minor)
    }
}
