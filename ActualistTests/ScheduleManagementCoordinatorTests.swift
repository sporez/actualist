import Foundation
import Testing
@testable import Actualist

@MainActor
@Suite("Schedule management coordinator")
struct ScheduleManagementCoordinatorTests {
    @Test func duplicateSubmitIsExcludedAndRefreshPendingRemainsCommitted() async {
        let store = ScheduleManagementRepositoryFake()
        let transactionRepository = RecordingTransactionRepository(
            editorOptionsResult: TransactionEditorOptions(
                accounts: [ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)],
                categories: [],
                categoryGroups: [],
                payees: []
            )
        )
        let coordinator = ScheduleManagementCoordinator()

        coordinator.beginCreate(
            expectedBudgetID: "budget",
            expectedGeneration: 1,
            today: "2026-09-28",
            currency: .usd,
            isPrivacyModeEnabled: false,
            mutationRepository: store,
            transactionRepository: transactionRepository
        )
        await ObservedTestState {
            if case .editing = coordinator.state { true } else { false }
        }.wait()
        coordinator.reviewSave(locale: Locale(identifier: "en_US"))
        guard case .editing(let invalidSession) = coordinator.state else {
            Issue.record("An incomplete schedule must remain in the editor")
            return
        }
        #expect(invalidSession.notice == "Choose an open account.")
        coordinator.setAccount("checking")
        guard case .editing(let correctedSession) = coordinator.state else {
            Issue.record("Choosing an account must keep the editor open")
            return
        }
        #expect(correctedSession.notice == nil)
        coordinator.setAmount("12.34")
        coordinator.reviewSave(locale: Locale(identifier: "en_US"))
        coordinator.confirmSave(locale: Locale(identifier: "en_US"), mutationRepository: store)
        coordinator.confirmSave(locale: Locale(identifier: "en_US"), mutationRepository: store)

        await ObservedTestState {
            if case .committed = coordinator.state { true } else { false }
        }.wait()
        guard case .committed(let outcome) = coordinator.state else {
            Issue.record("Expected a durable schedule receipt")
            return
        }
        #expect(store.createCalls == 1)
        #expect(outcome.refreshPending)
        coordinator.finishCommitted()
        #expect(coordinator.state == .idle)
        #expect(store.createCalls == 1)
    }

    @Test func unchangedMutationOutcomeDoesNotRequestScheduleRefresh() async {
        let store = ScheduleManagementRepositoryFake()
        store.createOutcome = ScheduleMutationOutcome(
            receipt: ScheduleMutationResult(
                scheduleID: "new-schedule",
                kind: .unchanged,
                appliedMessageCount: 0
            ),
            refreshPending: false
        )
        let coordinator = ScheduleManagementCoordinator()
        coordinator.beginCreate(
            expectedBudgetID: "budget",
            expectedGeneration: 1,
            today: "2026-09-28",
            currency: .usd,
            isPrivacyModeEnabled: false,
            mutationRepository: store,
            transactionRepository: RecordingTransactionRepository(
                editorOptionsResult: TransactionEditorOptions(
                    accounts: [ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)],
                    categories: [],
                    categoryGroups: [],
                    payees: []
                )
            )
        )
        await ObservedTestState {
            if case .editing = coordinator.state { true } else { false }
        }.wait()
        coordinator.setAccount("checking")
        coordinator.setAmount("12.34")
        coordinator.reviewSave(locale: Locale(identifier: "en_US"))
        coordinator.confirmSave(locale: Locale(identifier: "en_US"), mutationRepository: store)

        await ObservedTestState {
            if case .noChanges = coordinator.state { true } else { false }
        }.wait()

        guard case .noChanges(let outcome) = coordinator.state else {
            Issue.record("Expected the no-op outcome to remain reviewable")
            return
        }
        #expect(outcome.receipt.kind == .unchanged)
        #expect(coordinator.contentRevision == 0)
        #expect(store.refreshCalls == 0)
    }

    @Test func staleBudgetSessionCannotSubmitReviewedCreate() async {
        let store = ScheduleManagementRepositoryFake()
        let transactionRepository = RecordingTransactionRepository(
            editorOptionsResult: TransactionEditorOptions(
                accounts: [ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)],
                categories: [],
                categoryGroups: [],
                payees: []
            )
        )
        let coordinator = ScheduleManagementCoordinator()
        coordinator.beginCreate(
            expectedBudgetID: "budget",
            expectedGeneration: 1,
            today: "2026-09-28",
            currency: .usd,
            isPrivacyModeEnabled: false,
            mutationRepository: store,
            transactionRepository: transactionRepository
        )
        await ObservedTestState {
            if case .editing = coordinator.state { true } else { false }
        }.wait()
        coordinator.setAccount("checking")
        coordinator.setAmount("12.34")
        coordinator.reviewSave(locale: Locale(identifier: "en_US"))
        store.generation = 2

        coordinator.confirmSave(locale: Locale(identifier: "en_US"), mutationRepository: store)

        #expect(store.createCalls == 0)
        if case .failed(let message) = coordinator.state {
            #expect(message.contains("budget changed"))
        } else {
            Issue.record("A stale session must be presented as recoverable failure")
        }
    }

    @Test func createContextChangeWhileLoadingEndsInRecoverableFailure() async {
        let store = ScheduleManagementRepositoryFake()
        store.bumpGenerationAfterFirstContextRead = true
        let coordinator = ScheduleManagementCoordinator()

        coordinator.beginCreate(
            expectedBudgetID: "budget",
            expectedGeneration: 1,
            today: "2026-09-28",
            currency: .usd,
            isPrivacyModeEnabled: false,
            mutationRepository: store,
            transactionRepository: RecordingTransactionRepository(
                editorOptionsResult: TransactionEditorOptions(
                    accounts: [], categories: [], categoryGroups: [], payees: []
                )
            )
        )
        // The coordinator checks the context a second time, synchronously
        // followed by its state change, so the state is settled once this resumes.
        await store.secondContextRead.wait()

        guard case .failed(let message) = coordinator.state else {
            Issue.record("A context change while loading must not leave the editor loading")
            return
        }
        #expect(message.contains("budget changed"))
    }

    @Test func cancelWhileLoadingInvalidatesTheEditorPresentation() {
        let store = ScheduleManagementRepositoryFake()
        let coordinator = ScheduleManagementCoordinator()
        coordinator.beginCreate(
            expectedBudgetID: "budget",
            expectedGeneration: 1,
            today: "2026-09-28",
            currency: .usd,
            isPrivacyModeEnabled: false,
            mutationRepository: store,
            transactionRepository: RecordingTransactionRepository()
        )

        coordinator.cancel()

        #expect(coordinator.state == .idle)
        #expect(!coordinator.isSubmitting)
    }

    @Test func unsupportedSchemaSaveFailureSurfacesTesterVoicedNotice() async {
        let cases: [(any Error, String)] = [
            (
                ScheduleMutationCommandError.unsupportedSchema,
                ScheduleMutationUserNotice.unsupportedBudgetSchedules
            ),
            (
                ScheduleMutationCommandError.unsupportedSchema,
                ScheduleMutationUserNotice.unsupportedBudgetSchedules
            ),
            (
                ScheduleMutationCommandError.unsupportedCapability(
                    "This budget does not support schedule names."
                ),
                "This budget does not support schedule names."
            ),
            (
                LocalFirstError.invalidLocalWrite("missing column schedules.tombstone"),
                ScheduleMutationUserNotice.saveFailed
            )
        ]
        for (createError, expectedNotice) in cases {
            let store = ScheduleManagementRepositoryFake()
            store.createError = createError
            let coordinator = ScheduleManagementCoordinator()
            coordinator.beginCreate(
                expectedBudgetID: "budget",
                expectedGeneration: 1,
                today: "2026-09-28",
                currency: .usd,
                isPrivacyModeEnabled: false,
                mutationRepository: store,
                transactionRepository: RecordingTransactionRepository(
                    editorOptionsResult: TransactionEditorOptions(
                        accounts: [ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)],
                        categories: [],
                        categoryGroups: [],
                        payees: []
                    )
                )
            )
            await ObservedTestState {
                if case .editing = coordinator.state { true } else { false }
            }.wait()
            coordinator.setAccount("checking")
            coordinator.setAmount("12.34")
            coordinator.reviewSave(locale: Locale(identifier: "en_US"))
            coordinator.confirmSave(locale: Locale(identifier: "en_US"), mutationRepository: store)

            await ObservedTestState {
                if case .editing = coordinator.state { true } else { false }
            }.wait()

            guard case .editing(let session) = coordinator.state else {
                Issue.record("A failed save must reopen the editor with a notice")
                return
            }
            #expect(session.notice == expectedNotice)
            #expect(session.notice?.contains("missing column") != true)
        }
    }

    @Test func lateScheduleReviewAfterCancellationCannotOpenEditor() async {
        let store = ScheduleManagementRepositoryFake()
        store.pauseNextReview = true
        let coordinator = ScheduleManagementCoordinator()
        coordinator.beginEdit(
            detail: makeDetail(),
            expectedBudgetID: "budget",
            expectedGeneration: 1,
            today: "2026-09-28",
            currency: .usd,
            isPrivacyModeEnabled: false,
            scheduleRepository: store,
            mutationRepository: store,
            transactionRepository: RecordingTransactionRepository()
        )
        defer { store.releaseReview.trip() }

        guard await store.waitForReviewEntry() else {
            let canceledOperation = coordinator.cancel()
            store.releaseReview.trip()
            await canceledOperation?.value
            Issue.record("The schedule review did not reach its bounded gate")
            return
        }
        let canceledOperation = coordinator.cancel()
        store.releaseReview.trip()
        // The fake intentionally completes its suspended review despite cancellation.
        // Awaiting the canceled coordinator task proves it processed and rejected that
        // late result before the state assertion below.
        await canceledOperation?.value

        #expect(coordinator.state == .idle)
        #expect(store.refreshCalls == 0)
    }

    private func makeDetail() -> ScheduleDetail {
        ScheduleDetail(
            id: "schedule",
            ruleID: "rule",
            name: "Schedule",
            amount: .exact(-1_000),
            dateRule: .oneTime(dayID: "2026-09-28", operation: "is"),
            account: ScheduleAccountReference(id: "checking", name: "Checking", availability: .available),
            payee: SchedulePayeeReference(id: nil, name: nil, isMissing: false),
            effectiveNextDate: "2026-09-28",
            status: .upcoming,
            completed: false,
            postsTransaction: false,
            customUpcomingLength: nil,
            sortOrder: nil,
            rawConditionsJSON: nil,
            rawActionsJSON: nil,
            capabilities: ScheduleMutationCapabilities(
                canRead: true, canEditMetadata: true, canEditAccount: true,
                canEditPayee: true, canEditAmount: true, canEditDate: true,
                canSkip: false, canComplete: true, canDelete: true, canPost: false
            ),
            unsupportedReasons: [],
            occurrenceIdentity: ScheduleOccurrenceIdentity(
                scheduleID: "schedule",
                nextDateRowID: "next-date",
                effectiveNextDate: "2026-09-28",
                localNextDateTimestamp: "1",
                baseNextDateTimestamp: "1"
            )
        )
    }
}

@MainActor
private final class ScheduleManagementRepositoryFake: ScheduleRepositoryProtocol, ScheduleMutationRepositoryProtocol {
    var generation = 1
    var pauseNextReview = false
    var bumpGenerationAfterFirstContextRead = false
    private var contextReads = 0
    let secondContextRead = TestLatch()
    private(set) var createCalls = 0
    private(set) var refreshCalls = 0
    let reviewEntered = TestLatch()
    let releaseReview = TestLatch()
    private var didEnterReview = false
    private var reviewWaitTimedOut = false
    var createOutcome = ScheduleMutationOutcome(
        receipt: ScheduleMutationResult(scheduleID: "new-schedule", kind: .created, appliedMessageCount: 4),
        refreshPending: true
    )
    var createError: Error?

    func cachedSchedules(budgetID: String) -> LoadedSchedules? { nil }

    func refreshSchedules(budgetID: String, asOf today: String) async throws -> LoadedSchedules {
        refreshCalls += 1
        return LoadedSchedules.empty(budgetID: budgetID)
    }

    func waitForReviewEntry(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !self.didEnterReview else { return }
            self.reviewWaitTimedOut = true
            self.releaseReview.trip()
            self.reviewEntered.trip()
        }
        await reviewEntered.wait()
        deadline.cancel()
        return didEnterReview && !reviewWaitTimedOut
    }

    func scheduleMutationSessionContext(budgetID: String) throws -> ScheduleMutationSessionContext {
        contextReads += 1
        defer {
            if bumpGenerationAfterFirstContextRead {
                bumpGenerationAfterFirstContextRead = false
                generation += 1
            }
            if contextReads == 2 { secondContextRead.trip() }
        }
        return ScheduleMutationSessionContext(budgetID: budgetID, generation: generation)
    }

    func scheduleMutationReview(budgetID: String, scheduleID: String) async throws -> ReviewedScheduleMutation {
        if pauseNextReview {
            pauseNextReview = false
            didEnterReview = true
            reviewEntered.trip()
            await releaseReview.wait()
        }
        let context = ScheduleMutationSessionContext(budgetID: budgetID, generation: generation)
        let revision = ScheduleMutationReview(
            budgetID: budgetID,
            scheduleID: scheduleID,
            ruleID: "rule",
            schedule: ScheduleRowRevision(
                name: "Schedule", completed: false, postsTransaction: false,
                customUpcomingLength: nil, sortOrder: nil, tombstone: false, active: true
            ),
            rule: ScheduleRuleRevision(
                conditionsJSON: "[]", actionsJSON: "[]", stage: nil,
                conditionsOperation: "and", tombstone: false
            ),
            nextDates: [],
            account: nil
        )
        return ReviewedScheduleMutation(context: context, revision: revision)
    }

    func createSchedule(
        _ command: ScheduleCreateCommand,
        context: ScheduleMutationSessionContext
    ) async throws -> ScheduleMutationOutcome {
        if let createError { throw createError }
        createCalls += 1
        return createOutcome
    }

    func updateSchedule(
        review: ReviewedScheduleMutation,
        fields: ScheduleEditFields,
        asOfDayID: String,
        now: Date
    ) async throws -> ScheduleMutationOutcome {
        throw ScheduleMutationCommandError.invalidCommand("Not used by this test")
    }

    func deleteSchedule(review: ReviewedScheduleMutation) async throws -> ScheduleMutationOutcome {
        throw ScheduleMutationCommandError.invalidCommand("Not used by this test")
    }

    func skipNextDate(review: ReviewedScheduleMutation, now: Date) async throws -> ScheduleMutationOutcome {
        throw ScheduleMutationCommandError.invalidCommand("Not used by this test")
    }

    func completeSchedule(review: ReviewedScheduleMutation) async throws -> ScheduleMutationOutcome {
        throw ScheduleMutationCommandError.invalidCommand("Not used by this test")
    }
}
