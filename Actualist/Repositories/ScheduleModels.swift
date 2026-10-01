import Foundation

struct LoadedSchedules: Hashable, Sendable {
    let budgetID: String
    let schedules: [ScheduleSummary]
    let detailsByID: [String: ScheduleDetail]
    let defaultUpcomingLength: String

    static func empty(budgetID: String) -> LoadedSchedules {
        LoadedSchedules(
            budgetID: budgetID,
            schedules: [],
            detailsByID: [:],
            defaultUpcomingLength: "7"
        )
    }

    func detail(id: String) -> ScheduleDetail? {
        detailsByID[id]
    }
}

enum ScheduleStatus: String, CaseIterable, Hashable, Sendable {
    case completed
    case paid
    case due
    case upcoming
    case missed
    case scheduled

    static func resolve(
        nextDate: String,
        completed: Bool,
        hasMatchingTransaction: Bool,
        today: String,
        upcomingLength: String,
        calendar: Calendar = .actualScheduleGregorian
    ) -> ScheduleStatus {
        if completed { return .completed }
        if hasMatchingTransaction { return .paid }
        if nextDate == today { return .due }
        if nextDate < today { return .missed }
        guard let todayDate = ActualScheduleRecurrence.date(from: today, calendar: calendar),
              let nextDateValue = ActualScheduleRecurrence.date(from: nextDate, calendar: calendar),
              let end = calendar.date(
                  byAdding: .day,
                  value: ScheduleUpcomingLength.days(for: upcomingLength, today: today, calendar: calendar),
                  to: todayDate
              ) else {
            return .scheduled
        }
        return nextDateValue <= end ? .upcoming : .scheduled
    }
}

enum ScheduleAmount: Hashable, Sendable {
    case exact(Int)
    case approximate(Int)
    case range(lower: Int, upper: Int, postingAmount: Int)
    case unavailable

    var postingAmount: Int? {
        switch self {
        case .exact(let amount), .approximate(let amount): amount
        case .range(_, _, let amount): amount
        case .unavailable: nil
        }
    }
}

enum ScheduleDateRule: Hashable, Sendable {
    case oneTime(dayID: String, operation: String)
    case recurring(ActualScheduleRecurrence, operation: String)
    case unavailable

    var recurrence: ActualScheduleRecurrence? {
        guard case .recurring(let recurrence, _) = self else { return nil }
        return recurrence
    }
}

enum ScheduleOccurrenceMatchingMode: Hashable, Sendable {
    case exact
    case approximate
}

enum ScheduleReferenceAvailability: String, Hashable, Sendable {
    case available
    case closed
    case missing
}

struct ScheduleAccountReference: Hashable, Sendable {
    let id: String?
    let name: String?
    let availability: ScheduleReferenceAvailability
}

struct SchedulePayeeReference: Hashable, Sendable {
    let id: String?
    let name: String?
    let isMissing: Bool
}

enum ScheduleUnsupportedReason: Hashable, Sendable {
    case missingRule
    case malformedConditions
    case malformedActions
    case missingDate
    case unsupportedDate
    case missingAmount
    case unsupportedAmount
    case unsupportedActions
    case corruptRuleLinkage
    case missingNextDate
    case ambiguousNextDate

    var message: String {
        switch self {
        case .missingRule: "The linked rule is unavailable."
        case .malformedConditions, .malformedActions: "The linked rule cannot be read safely."
        case .missingDate, .unsupportedDate: "The schedule uses date options Actualist cannot safely interpret."
        case .missingAmount, .unsupportedAmount: "The schedule uses amount options Actualist cannot safely interpret."
        case .unsupportedActions: "Created with schedule actions Actualist cannot safely edit."
        case .corruptRuleLinkage: "The linked rule does not point back to this schedule."
        case .missingNextDate, .ambiguousNextDate: "The next occurrence is unavailable."
        }
    }
}

struct ScheduleMutationCapabilities: Hashable, Sendable {
    let canRead: Bool
    let canEditMetadata: Bool
    let canEditAccount: Bool
    let canEditPayee: Bool
    let canEditAmount: Bool
    let canEditDate: Bool
    let canSkip: Bool
    let canComplete: Bool
    let canDelete: Bool
    let canPost: Bool

    var canEdit: Bool {
        canEditMetadata || canEditAccount || canEditPayee || canEditAmount || canEditDate
    }

}

struct ScheduleOccurrenceIdentity: Hashable, Sendable {
    let scheduleID: String
    let nextDateRowID: String?
    let effectiveNextDate: String?
    let localNextDateTimestamp: String?
    let baseNextDateTimestamp: String?
}

struct ScheduleSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let amount: ScheduleAmount
    let account: ScheduleAccountReference
    let payee: SchedulePayeeReference
    let effectiveNextDate: String?
    let status: ScheduleStatus
    let postsTransaction: Bool
    let sortOrder: Double?
    let unsupportedReasons: [ScheduleUnsupportedReason]

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unnamed schedule" : trimmed
    }

    var isSupported: Bool { unsupportedReasons.isEmpty }
}

struct ScheduleDetail: Identifiable, Hashable, Sendable {
    let id: String
    let ruleID: String?
    let name: String?
    let amount: ScheduleAmount
    let dateRule: ScheduleDateRule
    let account: ScheduleAccountReference
    let payee: SchedulePayeeReference
    let effectiveNextDate: String?
    let status: ScheduleStatus
    let completed: Bool
    let postsTransaction: Bool
    let customUpcomingLength: String?
    let sortOrder: Double?
    let rawConditionsJSON: String?
    let rawActionsJSON: String?
    let capabilities: ScheduleMutationCapabilities
    let unsupportedReasons: [ScheduleUnsupportedReason]
    let occurrenceIdentity: ScheduleOccurrenceIdentity

    var summary: ScheduleSummary {
        ScheduleSummary(
            id: id,
            name: name,
            amount: amount,
            account: account,
            payee: payee,
            effectiveNextDate: effectiveNextDate,
            status: status,
            postsTransaction: postsTransaction,
            sortOrder: sortOrder,
            unsupportedReasons: unsupportedReasons
        )
    }
}

enum ScheduleUpcomingLength {
    static func days(
        for value: String,
        today: String,
        calendar: Calendar = .actualScheduleGregorian
    ) -> Int {
        guard let todayDate = ActualScheduleRecurrence.date(from: today, calendar: calendar) else { return 7 }
        switch value {
        case "currentMonth":
            guard let range = calendar.range(of: .day, in: .month, for: todayDate) else { return 7 }
            return max(range.count - calendar.component(.day, from: todayDate), 0)
        case "oneMonth":
            guard let monthStart = calendar.dateInterval(of: .month, for: todayDate)?.start,
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
                  let days = calendar.dateComponents([.day], from: monthStart, to: nextMonth).day else { return 7 }
            return days
        default:
            let components = value.split(separator: "-", maxSplits: 1).map(String.init)
            if components.count == 2, let count = Int(components[0]) {
                let safeCount = max(count, 1)
                switch components[1] {
                case "day": return safeCount
                case "week":
                    let days = safeCount.multipliedReportingOverflow(by: 7)
                    return days.overflow ? 7 : days.partialValue
                case "month", "year":
                    let months: Int
                    if components[1] == "year" {
                        let result = safeCount.multipliedReportingOverflow(by: 12)
                        guard !result.overflow else { return 7 }
                        months = result.partialValue
                    } else {
                        months = safeCount
                    }
                    guard let monthStart = calendar.dateInterval(of: .month, for: todayDate)?.start,
                          let future = calendar.date(byAdding: .month, value: months, to: todayDate),
                          let days = calendar.dateComponents([.day], from: monthStart, to: future).day else { return 7 }
                    let inclusiveDays = days.addingReportingOverflow(1)
                    return inclusiveDays.overflow ? 7 : inclusiveDays.partialValue
                default: return 7
                }
            }
            return Int(value) ?? 7
        }
    }
}
