import Foundation

/// A deterministic reason a scheduled occurrence cannot be posted. Thrown at the
/// source so callers never match on message text, and so automatic advancement
/// can skip one refused schedule without stopping the others.
enum SchedulePostingRefusal: Error, Hashable, Sendable {
    case invalidCommand
    case unsupportedOccurrence
    case accountUnavailable
    case occurrenceUnavailable
    case occurrenceDateMismatch
    case draftMismatch
    case ruleDeletesTransaction
    case ruleChangedScheduleLink
    /// The budget's tables lack something this occurrence's transaction graph needs.
    case unsupportedBudgetSchema
    /// The schedule's rule or transfer points at an account, category or payee that was
    /// deleted or closed. The user can fix this by editing the rule or reopening the account.
    case referencedRowUnavailable
    case beforeMatchWindow(earliestDayID: String)
}

extension SchedulePostingRefusal: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidCommand, .unsupportedOccurrence:
            "This schedule cannot be posted safely."
        case .accountUnavailable, .occurrenceUnavailable:
            "This schedule occurrence is no longer available to post."
        case .occurrenceDateMismatch, .draftMismatch:
            "This schedule changed during sync. Review its latest details and try again."
        case .unsupportedBudgetSchema:
            "This budget's file layout does not support posting this schedule."
        case .referencedRowUnavailable:
            "This schedule's rule or transfer points to an account, category, or payee that was deleted or closed. Edit the schedule's rule or reopen the account, then post it again."
        case .ruleDeletesTransaction:
            "A matching rule removes this scheduled transaction, so it cannot be posted."
        case .ruleChangedScheduleLink:
            "A matching rule changed the transaction's schedule link, so Actual will not mark this occurrence as paid. Update the rule to keep it linked to this schedule."
        case .beforeMatchWindow(let earliestDayID):
            "The transaction date is before Actual's payment match window for this occurrence, so Actual will not mark it as paid. Choose a date on or after \(earliestDayID) or update the matching rule's date."
        }
    }
}
