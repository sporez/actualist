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
            fragment(
                draft,
                currency: currency,
                randomized: randomized,
                seed: "\(seed)-\(index)"
            )
        }
        .joined(separator: " · ")
    }

    private static func fragment(
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
            guard let upTo = value.upTo else {
                return "\(amount)/mo"
            }
            let cap = formattedAmount(
                upTo.amount,
                currency: currency,
                randomized: randomized,
                seed: "\(seed)-cap"
            )
            return upTo.hold ? "\(amount)/mo hold \(cap)" : "\(amount)/mo up to \(cap)"
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
            return "Limit \(amount)/\(cadence)"
        case .refill:
            return "Refill"
        case .copy(let value):
            if value.lookBack == 1 {
                return "Copy last month"
            }
            return "Copy \(value.lookBack) months ago"
        case .average(let value):
            return "\(value.numMonths)-month average"
        case .schedule(let value):
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Schedule" : name
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
