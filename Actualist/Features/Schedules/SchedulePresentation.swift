import Foundation

struct SchedulesBudgetIdentity: Hashable, Sendable {
    let budgetID: String
    let sessionGeneration: Int
}

struct SchedulesViewContext: Hashable, Sendable {
    let identity: SchedulesBudgetIdentity
    let currency: BudgetCurrency
    let isPrivacyModeEnabled: Bool
    let asOfDayID: String

    static func currentDay(now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return ActualScheduleRecurrence.dayID(from: now, calendar: calendar)
    }
}

enum ScheduleListSectionKind: String, CaseIterable, Identifiable, Sendable {
    case missed
    case due
    case upcoming
    case paid
    case later
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missed: "Missed"
        case .due: "Due"
        case .upcoming: "Upcoming"
        case .paid: "Paid"
        case .later: "Later"
        case .completed: "Completed"
        }
    }
}

struct ScheduleListSection: Identifiable, Hashable, Sendable {
    let kind: ScheduleListSectionKind
    let rows: [ScheduleRowPresentation]

    var id: String { kind.id }
}

enum SchedulePresentationTone: Hashable, Sendable {
    case accent
    case positive
    case warning
    case danger
    case neutral
}

struct ScheduleRowPresentation: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let amountText: String
    let referenceText: String
    let dateText: String
    let status: ScheduleStatus
    let statusText: String
    let tone: SchedulePresentationTone
    let limitationText: String?

    var searchableText: String {
        [title, amountText, referenceText, dateText, statusText]
            .joined(separator: " ")
    }
}

struct ScheduleDetailPresentation: Hashable, Sendable {
    let title: String
    let amountText: String
    let statusText: String
    let statusTone: SchedulePresentationTone
    let stateText: String
    let dateText: String
    let recurrenceText: String
    let weekendText: String?
    let endingText: String?
    let upcomingWindowText: String
    let accountText: String
    let accountAvailability: ScheduleReferenceAvailability
    let payeeText: String
    let payeeIsMissing: Bool
    let automaticPostingText: String
    let unsupportedMessages: [String]
}

enum ScheduleListEmptyState: Hashable, Sendable {
    case none
    case noSchedules
    case noActiveSchedules
    case noMatches
}

enum SchedulePresentation {
    static func section(for status: ScheduleStatus) -> ScheduleListSectionKind {
        switch status {
        case .missed: .missed
        case .due: .due
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

    static func statusTone(_ status: ScheduleStatus) -> SchedulePresentationTone {
        switch status {
        case .completed, .scheduled: .neutral
        case .paid: .positive
        case .due: .warning
        case .upcoming: .accent
        case .missed: .danger
        }
    }

    static func row(
        _ schedule: ScheduleSummary,
        context: SchedulesViewContext
    ) -> ScheduleRowPresentation {
        ScheduleRowPresentation(
            id: schedule.id,
            title: displayName(
                schedule.displayName,
                id: schedule.id,
                privacyEnabled: context.isPrivacyModeEnabled
            ),
            amountText: amountLabel(
                schedule.amount,
                currency: context.currency,
                privacyEnabled: context.isPrivacyModeEnabled,
                seed: "schedule-\(schedule.id)"
            ),
            referenceText: referenceLabel(
                account: schedule.account,
                payee: schedule.payee,
                scheduleID: schedule.id,
                privacyEnabled: context.isPrivacyModeEnabled
            ),
            dateText: dateLabel(schedule.effectiveNextDate),
            status: schedule.status,
            statusText: statusLabel(schedule.status),
            tone: statusTone(schedule.status),
            limitationText: schedule.unsupportedReasons.isEmpty
                ? nil
                : "Some schedule options are unavailable"
        )
    }

    static func detail(
        _ detail: ScheduleDetail,
        defaultUpcomingLength: String,
        context: SchedulesViewContext
    ) -> ScheduleDetailPresentation {
        ScheduleDetailPresentation(
            title: displayName(
                detail.summary.displayName,
                id: detail.id,
                privacyEnabled: context.isPrivacyModeEnabled
            ),
            amountText: amountLabel(
                detail.amount,
                currency: context.currency,
                privacyEnabled: context.isPrivacyModeEnabled,
                seed: "schedule-\(detail.id)"
            ),
            statusText: statusLabel(detail.status),
            statusTone: statusTone(detail.status),
            stateText: detail.completed ? "Completed" : "Active",
            dateText: dateLabel(detail.effectiveNextDate),
            recurrenceText: recurrenceLabel(detail.dateRule),
            weekendText: weekendLabel(detail.dateRule),
            endingText: endingLabel(detail.dateRule),
            upcomingWindowText: upcomingWindowLabel(
                detail.customUpcomingLength ?? defaultUpcomingLength,
                usesBudgetDefault: detail.customUpcomingLength == nil
            ),
            accountText: accountLabel(
                detail.account,
                scheduleID: detail.id,
                privacyEnabled: context.isPrivacyModeEnabled
            ),
            accountAvailability: detail.account.availability,
            payeeText: payeeLabel(
                detail.payee,
                scheduleID: detail.id,
                privacyEnabled: context.isPrivacyModeEnabled
            ),
            payeeIsMissing: detail.payee.isMissing,
            automaticPostingText: detail.postsTransaction ? "Enabled" : "Disabled",
            unsupportedMessages: detail.unsupportedReasons.reduce(into: []) { messages, reason in
                if !messages.contains(reason.message) {
                    messages.append(reason.message)
                }
            }
        )
    }

    static func amountLabel(
        _ amount: ScheduleAmount,
        currency: BudgetCurrency,
        privacyEnabled: Bool,
        seed: String
    ) -> String {
        switch amount {
        case .exact(let value):
            return currency.formatted(displayAmount(
                value,
                seed: seed,
                currency: currency,
                privacyEnabled: privacyEnabled
            ))
        case .approximate(let value):
            let displayed = displayAmount(
                value,
                seed: seed,
                currency: currency,
                privacyEnabled: privacyEnabled
            )
            return "About \(currency.formatted(displayed))"
        case .range(let lower, let upper, _):
            let displayed = [
                displayAmount(
                    lower,
                    seed: "\(seed)-lower",
                    currency: currency,
                    privacyEnabled: privacyEnabled
                ),
                displayAmount(
                    upper,
                    seed: "\(seed)-upper",
                    currency: currency,
                    privacyEnabled: privacyEnabled
                )
            ].sorted()
            return "\(currency.formatted(displayed[0])) – \(currency.formatted(displayed[1]))"
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
            let frequency = interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)"
            guard !recurrence.patterns.isEmpty else { return frequency }
            return "\(frequency) • \(recurrence.patterns.map(patternLabel).joined(separator: ", "))"
        }
    }

    private static func displayName(
        _ name: String,
        id: String,
        privacyEnabled: Bool
    ) -> String {
        guard privacyEnabled else { return name }
        let suffix = Int(PrivacyDisplay.stableHash("schedule-name-\(id)") % 90) + 10
        return "Sample Schedule \(suffix)"
    }

    private static func displayAmount(
        _ amount: Int,
        seed: String,
        currency: BudgetCurrency,
        privacyEnabled: Bool
    ) -> Int {
        guard privacyEnabled else { return amount }
        return PrivacyDisplay.amount(amount, seed: seed, currency: currency)
    }

    private static func referenceLabel(
        account: ScheduleAccountReference,
        payee: SchedulePayeeReference,
        scheduleID: String,
        privacyEnabled: Bool
    ) -> String {
        [
            payeeLabel(
                payee,
                scheduleID: scheduleID,
                privacyEnabled: privacyEnabled
            ),
            accountLabel(
                account,
                scheduleID: scheduleID,
                privacyEnabled: privacyEnabled
            )
        ].joined(separator: " • ")
    }

    private static func accountLabel(
        _ account: ScheduleAccountReference,
        scheduleID: String,
        privacyEnabled: Bool
    ) -> String {
        guard account.availability != .missing else { return "Unavailable account" }
        let name: String
        if privacyEnabled {
            name = PrivacyDisplay.name(
                for: .account,
                seed: "schedule-account-\(account.id ?? scheduleID)"
            )
        } else {
            name = account.name ?? "Unavailable account"
        }
        return account.availability == .closed ? "\(name) (Closed)" : name
    }

    private static func payeeLabel(
        _ payee: SchedulePayeeReference,
        scheduleID: String,
        privacyEnabled: Bool
    ) -> String {
        if payee.isMissing { return "Unavailable payee" }
        guard payee.id != nil || payee.name != nil else { return "No payee" }
        if privacyEnabled {
            return PrivacyDisplay.name(
                for: .payee,
                seed: "schedule-payee-\(payee.id ?? scheduleID)"
            )
        }
        return payee.name ?? "Unavailable payee"
    }

    private static func weekendLabel(_ rule: ScheduleDateRule) -> String? {
        guard case .recurring(let recurrence, _) = rule,
              recurrence.skipWeekend else { return nil }
        switch recurrence.weekendAdjustment {
        case .before: return "Move to the weekday before"
        case .after: return "Move to the weekday after"
        }
    }

    private static func endingLabel(_ rule: ScheduleDateRule) -> String? {
        guard case .recurring(let recurrence, _) = rule else { return nil }
        switch recurrence.ending {
        case .never:
            return "No end date"
        case .afterOccurrences(let count):
            return "After \(count) \(count == 1 ? "occurrence" : "occurrences")"
        case .onDate(let dayID):
            return dateLabel(dayID)
        }
    }

    private static func upcomingWindowLabel(
        _ value: String,
        usesBudgetDefault: Bool
    ) -> String {
        let label: String
        switch value {
        case "currentMonth": label = "Through the current month"
        case "oneMonth": label = "One month"
        default:
            let components = value.split(separator: "-", maxSplits: 1).map(String.init)
            if components.count == 2, let count = Int(components[0]) {
                let unit = count == 1 ? components[1] : "\(components[1])s"
                label = "\(count) \(unit)"
            } else if let days = Int(value) {
                label = "\(days) \(days == 1 ? "day" : "days")"
            } else {
                label = "Custom window"
            }
        }
        return usesBudgetDefault ? "\(label) (Budget default)" : label
    }

    private static func patternLabel(_ pattern: ActualSchedulePattern) -> String {
        switch pattern {
        case .dayOfMonth(let day):
            if day > 0 { return "day \(day)" }
            return day == -1 ? "last day" : "\(ordinal(-day))-to-last day"
        case .weekday(let weekday, let position):
            let weekdayName: String
            switch weekday {
            case .sunday: weekdayName = "Sunday"
            case .monday: weekdayName = "Monday"
            case .tuesday: weekdayName = "Tuesday"
            case .wednesday: weekdayName = "Wednesday"
            case .thursday: weekdayName = "Thursday"
            case .friday: weekdayName = "Friday"
            case .saturday: weekdayName = "Saturday"
            }
            if position > 0 { return "\(ordinal(position)) \(weekdayName)" }
            return position == -1
                ? "last \(weekdayName)"
                : "\(ordinal(-position))-to-last \(weekdayName)"
        }
    }

    private static func ordinal(_ value: Int) -> String {
        let suffix: String
        let finalTwoDigits = value % 100
        if (11...13).contains(finalTwoDigits) {
            suffix = "th"
        } else {
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }
}
