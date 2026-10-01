import Foundation

enum SchedulePostingDate: Hashable, Sendable {
    case scheduled
    case today(dayID: String)
}

enum SchedulePostingPhase: Hashable, Sendable {
    case submitting
}

struct SchedulePostingAvailability: Hashable, Sendable {
    let canPost: Bool
    let reason: String?
}

struct SchedulePostingReview: Hashable, Sendable {
    let session: ScheduleMutationSessionContext
    let mutation: ScheduleMutationReview
}

struct SchedulePostingReceipt: Hashable, Sendable {
    let scheduleID: String
    let transactionID: String
    let occurrenceDayID: String
    let postedDayID: String
    let appliedMessageCount: Int
    let refreshPending: Bool
}

enum SchedulePostingError: Error, Hashable, Sendable {
    case syncRequired
    case reviewChanged
    case occurrenceNoLongerPostable
    case unsupportedSchedule
    case alreadyInFlight
}

extension SchedulePostingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .syncRequired:
            "Connect and sync this budget before posting a scheduled transaction."
        case .reviewChanged:
            "This schedule changed during sync. Review its latest details and try again."
        case .occurrenceNoLongerPostable:
            "This schedule occurrence is no longer available to post."
        case .unsupportedSchedule:
            "This schedule cannot be posted safely."
        case .alreadyInFlight:
            "A post for this schedule is already in progress."
        }
    }
}

@MainActor
protocol SchedulePostingRepositoryProtocol: AnyObject {
    func schedulePostingAvailability(budgetID: String) throws -> SchedulePostingAvailability
    func schedulePostingReview(budgetID: String, scheduleID: String) async throws -> SchedulePostingReview
    func postSchedule(
        review: SchedulePostingReview,
        date: SchedulePostingDate,
        onPhaseChange: @escaping @MainActor @Sendable (SchedulePostingPhase) -> Void
    ) async throws -> SchedulePostingReceipt
}
