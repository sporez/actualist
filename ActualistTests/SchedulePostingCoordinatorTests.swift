import Foundation
import Testing
@testable import Actualist

@MainActor
@Suite("Schedule posting coordinator")
struct SchedulePostingCoordinatorTests {
    @Test func reviewPreparesSelectedOccurrenceAndUnavailableSyncReason() async {
        let repository = SchedulePostingCoordinatorRepositoryFake()
        repository.availability = SchedulePostingAvailability(
            canPost: false,
            reason: "Demo budgets cannot be remotely synced."
        )
        let coordinator = SchedulePostingCoordinator()
        coordinator.beginReview(
            scheduleID: "rent",
            expectedBudgetID: "budget",
            expectedGeneration: 4,
            today: "2026-09-28",
            currency: .usd,
            isPrivacyModeEnabled: false,
            scheduleRepository: repository,
            postingRepository: repository
        )
        await waitForReview(coordinator)

        guard case .review(let review) = coordinator.state else {
            Issue.record("Expected a prepared review")
            return
        }
        #expect(review.amountText == SchedulePresentation.amountLabel(
            .exact(-10_000), currency: .usd, privacyEnabled: false, seed: "schedule-post-rent"
        ))
        #expect(review.scheduledDateText == SchedulePresentation.dateLabel("2026-09-28"))
        #expect(review.selectedDate == .scheduled)
        #expect(!review.canSubmit)
        #expect(review.unavailableReason?.contains("Demo budgets") == true)
        coordinator.selectDate(.today(dayID: review.todayDayID))
        guard case .review(let changed) = coordinator.state else {
            Issue.record("Expected selected date to remain in review state")
            return
        }
        #expect(changed.selectedDate == .today(dayID: "2026-09-28"))
        #expect(!changed.canSubmit)
    }

    @Test func duplicateConfirmationWaitsForOneSyncFirstSubmission() async {
        let repository = SchedulePostingCoordinatorRepositoryFake()
        repository.pausePostBeforeSyncCompletion = true
        let coordinator = await preparedCoordinator(repository)
        guard case .review(let reviewedContent) = coordinator.state else {
            Issue.record("Expected a prepared review before confirmation")
            return
        }

        coordinator.confirm(postingRepository: repository)
        await repository.postEntered.wait()
        coordinator.confirm(postingRepository: repository)
        #expect(repository.postCalls == 1)
        #expect(coordinator.state == .syncing(reviewedContent))
        repository.syncRelease.trip()
        await repository.commitEntered.wait()
        #expect(coordinator.state == .submitting(reviewedContent))
        repository.commitRelease.trip()
        await waitForCommitted(coordinator)
        #expect(repository.postCalls == 1)
    }

    @Test func syncFailureIsVisibleAndNeverEntersSubmitPhase() async {
        let repository = SchedulePostingCoordinatorRepositoryFake()
        repository.postError = SchedulePostingTestError.syncFailed
        let coordinator = await preparedCoordinator(repository)

        coordinator.confirm(postingRepository: repository)
        await waitForFailure(coordinator)

        #expect(repository.postCalls == 1)
        #expect(!repository.didEnterSubmitPhase)
        if case .failed(let message) = coordinator.state {
            #expect(message.contains("sync failed"))
        }
    }

    @Test func canceledSyncLateCompletionCannotReplaceIdleState() async {
        let repository = SchedulePostingCoordinatorRepositoryFake()
        repository.pausePostBeforeSyncCompletion = true
        repository.cancellationAfterSyncGate = true
        let coordinator = await preparedCoordinator(repository)

        coordinator.confirm(postingRepository: repository)
        await repository.postEntered.wait()
        let canceledTask = coordinator.cancel()
        repository.syncRelease.trip()
        await canceledTask?.value

        #expect(coordinator.state == .idle)
        #expect(!repository.didEnterSubmitPhase)
    }

    @Test func committedRefreshPendingCannotBeCanceledIntoFailure() async {
        let repository = SchedulePostingCoordinatorRepositoryFake()
        repository.receipt = SchedulePostingReceipt(
            scheduleID: "rent",
            transactionID: "committed-transaction",
            occurrenceDayID: "2026-09-28",
            postedDayID: "2026-09-28",
            appliedMessageCount: 8,
            refreshPending: true
        )
        let coordinator = await preparedCoordinator(repository)

        coordinator.confirm(postingRepository: repository)
        await repository.commitEntered.wait()
        #expect(coordinator.state.isSubmitting)
        #expect(coordinator.cancel() == nil)
        repository.commitRelease.trip()
        await waitForCommitted(coordinator)

        guard case .committedRefreshPending(let receipt) = coordinator.state else {
            Issue.record("A committed write must not appear to have failed")
            return
        }
        #expect(receipt.transactionID == "committed-transaction")
    }

    private func preparedCoordinator(
        _ repository: SchedulePostingCoordinatorRepositoryFake
    ) async -> SchedulePostingCoordinator {
        let coordinator = SchedulePostingCoordinator()
        coordinator.beginReview(
            scheduleID: "rent",
            expectedBudgetID: "budget",
            expectedGeneration: 4,
            today: "2026-09-28",
            currency: .usd,
            isPrivacyModeEnabled: false,
            scheduleRepository: repository,
            postingRepository: repository
        )
        await waitForReview(coordinator)
        return coordinator
    }

    private func waitForReview(_ coordinator: SchedulePostingCoordinator) async {
        await ObservedTestState {
            if case .review = coordinator.state { true } else { false }
        }.wait()
    }

    private func waitForFailure(_ coordinator: SchedulePostingCoordinator) async {
        await ObservedTestState {
            if case .failed = coordinator.state { true } else { false }
        }.wait()
    }

    private func waitForCommitted(_ coordinator: SchedulePostingCoordinator) async {
        await ObservedTestState {
            switch coordinator.state {
            case .committed, .committedRefreshPending: true
            default: false
            }
        }.wait()
    }
}

private enum SchedulePostingTestError: Error, LocalizedError {
    case syncFailed

    var errorDescription: String? {
        "The scheduled transaction sync failed."
    }
}

@MainActor
private final class SchedulePostingCoordinatorRepositoryFake: ScheduleRepositoryProtocol, SchedulePostingRepositoryProtocol {
    var availability = SchedulePostingAvailability(canPost: true, reason: nil)
    var pausePostBeforeSyncCompletion = false
    var cancellationAfterSyncGate = false
    var postError: Error?
    var receipt = SchedulePostingReceipt(
        scheduleID: "rent", transactionID: "posted", occurrenceDayID: "2026-09-28", postedDayID: "2026-09-28",
        appliedMessageCount: 6, refreshPending: false
    )
    private(set) var postCalls = 0
    private(set) var didEnterSubmitPhase = false
    let postEntered = TestLatch()
    let syncRelease = TestLatch()
    let commitEntered = TestLatch()
    let commitRelease = TestLatch()

    func cachedSchedules(budgetID: String) -> LoadedSchedules? { nil }

    func refreshSchedules(budgetID: String, asOf today: String) async throws -> LoadedSchedules {
        LoadedSchedules(
            budgetID: budgetID,
            schedules: [makeDetail().summary],
            detailsByID: ["rent": makeDetail()],
            defaultUpcomingLength: "7"
        )
    }

    func schedulePostingAvailability(budgetID: String) throws -> SchedulePostingAvailability {
        availability
    }

    func schedulePostingReview(budgetID: String, scheduleID: String) async throws -> SchedulePostingReview {
        SchedulePostingReview(
            session: ScheduleMutationSessionContext(budgetID: budgetID, generation: 4),
            mutation: makeReview()
        )
    }

    func postSchedule(
        review: SchedulePostingReview,
        date: SchedulePostingDate,
        onPhaseChange: @escaping @MainActor @Sendable (SchedulePostingPhase) -> Void
    ) async throws -> SchedulePostingReceipt {
        postCalls += 1
        postEntered.trip()
        if pausePostBeforeSyncCompletion {
            await syncRelease.wait()
        }
        if cancellationAfterSyncGate { try Task.checkCancellation() }
        if let postError { throw postError }
        didEnterSubmitPhase = true
        onPhaseChange(.submitting)
        commitEntered.trip()
        await commitRelease.wait()
        return receipt
    }

    private func makeDetail() -> ScheduleDetail {
        ScheduleDetail(
            id: "rent", ruleID: "rent-rule", name: "Rent", amount: .exact(-10_000),
            dateRule: .oneTime(dayID: "2026-09-28", operation: "is"),
            account: ScheduleAccountReference(id: "checking", name: "Checking", availability: .available),
            payee: SchedulePayeeReference(id: "landlord", name: "Landlord", isMissing: false),
            effectiveNextDate: "2026-09-28", status: .due, completed: false,
            postsTransaction: false, customUpcomingLength: nil, sortOrder: 1,
            rawConditionsJSON: nil, rawActionsJSON: nil,
            capabilities: ScheduleMutationCapabilities(
                canRead: true, canEditMetadata: true, canEditAccount: true,
                canEditPayee: true, canEditAmount: true, canEditDate: true,
                canSkip: true, canComplete: false, canDelete: true, canPost: true
            ),
            unsupportedReasons: [],
            occurrenceIdentity: ScheduleOccurrenceIdentity(
                scheduleID: "rent", nextDateRowID: "rent-next", effectiveNextDate: "2026-09-28",
                localNextDateTimestamp: "1", baseNextDateTimestamp: "1"
            )
        )
    }

    private func makeReview() -> ScheduleMutationReview {
        ScheduleMutationReview(
            budgetID: "budget", scheduleID: "rent", ruleID: "rent-rule",
            schedule: ScheduleRowRevision(
                name: "Rent", completed: false, postsTransaction: false,
                customUpcomingLength: nil, sortOrder: 1, tombstone: false, active: true
            ),
            rule: ScheduleRuleRevision(
                conditionsJSON: "[]", actionsJSON: "[]", stage: "normal",
                conditionsOperation: "and", tombstone: false
            ),
            nextDates: [ScheduleNextDateRevision(
                id: "rent-next", localDate: "2026-09-28", localTimestamp: "1",
                baseDate: "2026-09-28", baseTimestamp: "1", tombstone: false
            )],
            account: ScheduleAccountRevision(
                id: "checking", name: "Checking", offBudget: false, isClosed: false, tombstone: false
            )
        )
    }
}
