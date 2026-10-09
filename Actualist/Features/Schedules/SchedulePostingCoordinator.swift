import Foundation
import Observation

struct SchedulePostingReviewContent: Hashable, Sendable {
    let review: SchedulePostingReview
    let scheduleID: String
    let title: String
    let amountText: String
    let statusText: String
    let accountText: String
    let payeeText: String
    let scheduledDateText: String
    let scheduledDayID: String?
    let todayDateText: String
    let todayDayID: String
    let selectedDate: SchedulePostingDate
    let canSubmit: Bool
    let unavailableReason: String?

    /// Shown when the chosen date falls before the scheduled date. Actual still
    /// posts it, but the schedule keeps waiting for its own occurrence.
    var earlyPostNotice: String? {
        guard canSubmit, case .today(let dayID) = selectedDate,
              let scheduledDayID, dayID < scheduledDayID else { return nil }
        return "The transaction will be dated today. The schedule may still show \(scheduledDateText) as upcoming."
    }
}

enum SchedulePostingCoordinatorState: Hashable, Sendable {
    case idle
    case loading
    case review(SchedulePostingReviewContent)
    case syncing(SchedulePostingReviewContent)
    case submitting(SchedulePostingReviewContent)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .loading, .syncing, .submitting: true
        case .idle, .review, .failed: false
        }
    }

    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }
}

@MainActor
@Observable
final class SchedulePostingCoordinator {
    private(set) var state: SchedulePostingCoordinatorState = .idle
    /// Bumped once per durable post. A durable post returns the coordinator to
    /// `.idle` (the sheet dismisses itself), so the presenting host reloads and
    /// plays the success haptic from this counter. A pending cache refresh needs
    /// no screen of its own; the host's reload covers it.
    private(set) var committedRevision: UInt64 = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    var isPresented: Bool {
        get { state != .idle }
        set { if !newValue { _ = cancel() } }
    }

    func beginReview(
        scheduleID: String,
        expectedBudgetID: String,
        expectedGeneration: Int,
        today: String,
        currency: BudgetCurrency,
        isPrivacyModeEnabled: Bool,
        scheduleRepository: any ScheduleRepositoryProtocol,
        postingRepository: any SchedulePostingRepositoryProtocol
    ) {
        guard !state.isBusy else { return }
        let request = beginRequest()
        state = .loading
        let availability: SchedulePostingAvailability
        do {
            availability = try postingRepository.schedulePostingAvailability(budgetID: expectedBudgetID)
        } catch {
            state = .failed(message(for: error))
            finish(request)
            return
        }

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let review = try await postingRepository.schedulePostingReview(
                    budgetID: expectedBudgetID,
                    scheduleID: scheduleID
                )
                try Task.checkCancellation()
                guard isCurrent(request) else { return }
                let schedules = try await scheduleRepository.refreshSchedules(
                    budgetID: expectedBudgetID,
                    asOf: today
                )
                try Task.checkCancellation()
                guard isCurrent(request) else { return }
                guard review.session.budgetID == expectedBudgetID,
                      review.session.generation == expectedGeneration,
                      review.mutation.scheduleID == scheduleID,
                      schedules.budgetID == expectedBudgetID,
                      let detail = schedules.detail(id: scheduleID) else {
                    state = .failed("The selected budget or schedule changed. Reopen the schedule and try again.")
                    finish(request)
                    return
                }
                let context = SchedulesViewContext(
                    identity: SchedulesBudgetIdentity(
                        budgetID: expectedBudgetID,
                        sessionGeneration: expectedGeneration
                    ),
                    currency: currency,
                    isPrivacyModeEnabled: isPrivacyModeEnabled,
                    asOfDayID: today
                )
                let presentation = SchedulePresentation.detail(
                    detail,
                    defaultUpcomingLength: schedules.defaultUpcomingLength,
                    context: context
                )
                let eligibleStatus = detail.status.allowsManualPosting
                let amount = detail.amount.postingAmount
                let scheduledDate = detail.effectiveNextDate
                let reason: String?
                if !availability.canPost {
                    reason = availability.reason ?? "Sync this budget before posting."
                } else if !detail.capabilities.canPost || !eligibleStatus || amount == nil || scheduledDate == nil {
                    reason = detail.unsupportedReasons.first?.message
                        ?? "This schedule occurrence is not available to post."
                } else if detail.account.availability != .available {
                    reason = "Choose an available account before posting this schedule."
                } else {
                    reason = nil
                }
                let amountText: String
                if let amount {
                    amountText = SchedulePresentation.amountLabel(
                        .exact(amount),
                        currency: currency,
                        privacyEnabled: isPrivacyModeEnabled,
                        seed: "schedule-post-\(scheduleID)"
                    )
                } else {
                    amountText = "Amount unavailable"
                }
                state = .review(SchedulePostingReviewContent(
                    review: review,
                    scheduleID: scheduleID,
                    title: presentation.title,
                    amountText: amountText,
                    statusText: presentation.statusText,
                    accountText: presentation.accountText,
                    payeeText: presentation.payeeText,
                    scheduledDateText: SchedulePresentation.dateLabel(scheduledDate),
                    scheduledDayID: scheduledDate,
                    todayDateText: SchedulePresentation.dateLabel(today),
                    todayDayID: today,
                    selectedDate: .scheduled,
                    canSubmit: reason == nil,
                    unavailableReason: reason
                ))
                finish(request)
            } catch {
                guard isCurrent(request) else { return }
                state = .failed(message(for: error))
                finish(request)
            }
        }
    }

    func selectDate(_ date: SchedulePostingDate) {
        guard case .review(let content) = state else { return }
        state = .review(replacing(content, date: date))
    }

    func confirm(postingRepository: any SchedulePostingRepositoryProtocol) {
        guard case .review(let content) = state, content.canSubmit,
              !state.isBusy,
              content.review.session.budgetID == content.review.mutation.budgetID else { return }
        let request = beginRequest()
        state = .syncing(content)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await postingRepository.postSchedule(
                    review: content.review,
                    date: content.selectedDate,
                    onPhaseChange: { [weak self] phase in
                        guard let self, isCurrent(request) else { return }
                        switch phase {
                        case .submitting:
                            state = .submitting(content)
                        }
                    }
                )
                guard isCurrent(request) else { return }
                state = .idle
                committedRevision &+= 1
                finish(request)
            } catch {
                guard isCurrent(request) else { return }
                state = .failed(message(for: error))
                finish(request)
            }
        }
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        guard !state.isSubmitting else { return nil }
        let canceled = operationTask
        canceled?.cancel()
        operationTask = nil
        generation &+= 1
        state = .idle
        return canceled
    }

    func dismissFailure() {
        guard case .failed = state else { return }
        _ = cancel()
    }

    private func beginRequest() -> Int {
        operationTask?.cancel()
        generation &+= 1
        return generation
    }

    private func finish(_ request: Int) {
        guard generation == request else { return }
        operationTask = nil
    }

    private func isCurrent(_ request: Int) -> Bool {
        generation == request && !Task.isCancelled
    }

    private func replacing(
        _ content: SchedulePostingReviewContent,
        date: SchedulePostingDate
    ) -> SchedulePostingReviewContent {
        SchedulePostingReviewContent(
            review: content.review,
            scheduleID: content.scheduleID,
            title: content.title,
            amountText: content.amountText,
            statusText: content.statusText,
            accountText: content.accountText,
            payeeText: content.payeeText,
            scheduledDateText: content.scheduledDateText,
            scheduledDayID: content.scheduledDayID,
            todayDateText: content.todayDateText,
            todayDayID: content.todayDayID,
            selectedDate: date,
            canSubmit: content.canSubmit,
            unavailableReason: content.unavailableReason
        )
    }

    private func message(for error: Error) -> String {
        error.userFacingMessage ?? error.localizedDescription
    }
}
