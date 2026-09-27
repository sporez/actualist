import Foundation

enum ScheduleListSectionKind: String, CaseIterable, Identifiable, Sendable {
    case needsAttention
    case upcoming
    case paid
    case later
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsAttention: "Needs Attention"
        case .upcoming: "Upcoming"
        case .paid: "Paid"
        case .later: "Later"
        case .completed: "Completed"
        }
    }
}

struct ScheduleListSection: Identifiable, Hashable, Sendable {
    let kind: ScheduleListSectionKind
    let schedules: [ScheduleSummary]

    var id: String { kind.id }
}

enum SchedulePresentation {
    static func section(for status: ScheduleStatus) -> ScheduleListSectionKind {
        switch status {
        case .missed, .due: .needsAttention
        case .upcoming: .upcoming
        case .paid: .paid
        case .scheduled: .later
        case .completed: .completed
        }
    }

    static func statusLabel(_ status: ScheduleStatus) -> String {
        switch status {
        case .completed: "Completed"
        case .paid: "Paid"
        case .due: "Due today"
        case .upcoming: "Upcoming"
        case .missed: "Missed"
        case .scheduled: "Scheduled"
        }
    }

    static func amountLabel(_ amount: ScheduleAmount, currency: BudgetCurrency) -> String {
        switch amount {
        case .exact(let value):
            return currency.formatted(value)
        case .approximate(let value):
            return "About \(currency.formatted(value))"
        case .range(let lower, let upper, _):
            return "\(currency.formatted(lower)) – \(currency.formatted(upper))"
        case .unavailable:
            return "Amount unavailable"
        }
    }

    static func dateLabel(_ dayID: String?) -> String {
        guard let dayID,
              let date = ActualScheduleRecurrence.date(from: dayID) else {
            return "Date unavailable"
        }
        var format = Date.FormatStyle.dateTime
            .month(.abbreviated)
            .day()
            .year()
        format.timeZone = .gmt
        return date.formatted(format)
    }

    static func recurrenceLabel(_ rule: ScheduleDateRule) -> String {
        switch rule {
        case .oneTime:
            return "One time"
        case .unavailable:
            return "Recurrence unavailable"
        case .recurring(let recurrence, _):
            let interval = recurrence.interval
            let unit: String
            switch recurrence.frequencyValue {
            case .daily: unit = interval == 1 ? "day" : "days"
            case .weekly: unit = interval == 1 ? "week" : "weeks"
            case .monthly: unit = interval == 1 ? "month" : "months"
            case .yearly: unit = interval == 1 ? "year" : "years"
            }
            return interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)"
        }
    }

    static func searchableText(
        _ schedule: ScheduleSummary,
        currency: BudgetCurrency
    ) -> String {
        [
            schedule.displayName,
            schedule.account.name ?? "Unavailable account",
            schedule.payee.name ?? (schedule.payee.isMissing ? "Unavailable payee" : "No payee"),
            schedule.effectiveNextDate ?? "Date unavailable",
            statusLabel(schedule.status),
            amountLabel(schedule.amount, currency: currency)
        ].joined(separator: " ")
    }
}
