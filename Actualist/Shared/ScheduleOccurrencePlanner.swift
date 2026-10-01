import Foundation

/// Entry action for one schedule occurrence, matching pinned Actual
/// `advanceSchedulesService` before its posting loop. Later loop steps — post,
/// then maybe advance a missed recurring schedule — are not folded in, and
/// this does not apply a uniqueness rule.
enum ScheduleAdvancementAction: Hashable, Sendable {
    case postScheduledDate
    case advanceRecurring
    case completeOneTime
    case stop
}

enum ScheduleOccurrencePlanner {
    /// An unavailable account or empty `nextDate` stops before either branch.
    /// Dates are plain `YYYY-MM-DD` strings, not calendar values.
    ///
    /// A paid occurrence stops on `today` only inside the posts-transaction
    /// branch. A paid recurring schedule that does not enter that branch still
    /// advances, including when `nextDate` is today.
    static func action(
        postsTransaction: Bool,
        isRecurring: Bool,
        nextDate: String,
        status: ScheduleStatus,
        accountAvailable: Bool,
        today: String
    ) -> ScheduleAdvancementAction {
        if !accountAvailable || nextDate.isEmpty {
            return .stop
        }

        if postsTransaction,
           (status != .paid || isRecurring),
           (status == .paid || status == .due || status == .missed) {
            if status == .paid {
                return nextDate == today ? .stop : .advanceRecurring
            }
            return .postScheduledDate
        }

        if status == .paid, isRecurring {
            return .advanceRecurring
        }

        if status == .paid, !isRecurring, nextDate < today {
            return .completeOneTime
        }

        return .stop
    }
}
