import Foundation

/// Entry action for one schedule occurrence, matching pinned Actual
/// `advanceSchedulesService` before its posting loop. Later loop steps — post,
/// then maybe advance a missed recurring schedule — are not folded in, and
/// this does not apply a uniqueness rule.
enum ScheduleAdvancementAction: Hashable, Sendable {
    case postScheduledDate
    case advanceRecurring
    /// Paid recurring schedule that does not post: next date is recomputed from today.
    case recomputeRecurring
    case completeOneTime
    case stop
}

enum ScheduleOccurrencePlanner {
    /// An unavailable account or empty `nextDate` stops before either branch.
    /// Dates are plain `YYYY-MM-DD` strings, not calendar values.
    ///
    /// A paid occurrence stops on `today` only inside the posts-transaction
    /// branch. A paid recurring schedule that does not enter that branch
    /// recomputes its next date from today, including when `nextDate` is today. This passes over missed occurrences, like Actual's `setNextDate` in the paid branch.
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
            return .recomputeRecurring
        }

        if status == .paid, !isRecurring, nextDate < today {
            return .completeOneTime
        }

        return .stop
    }
}
