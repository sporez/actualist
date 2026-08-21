import Foundation
import Testing
@testable import Actualist

/// Focused tests for `TransactionEditorSubmissionCoordinator` covering
/// create/update, `.submitting` → `.refetching` → `.clean` callback sequencing,
/// duplicate-submit rejection, create/refresh failure/retry, cancellation, and
/// stale-completion (a late callback after `cancel()` is a no-op).
@MainActor
struct TransactionEditorSubmissionCoordinatorTests {
    private static let testDate = Date(timeIntervalSince1970: 1_788_000_000)

    private func makeDraft(
        accountID: String = "checking",
        amountMinorUnits: Int = -1234,
        categoryID: String? = nil
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: accountID,
            date: Self.testDate,
            amountMinorUnits: amountMinorUnits,
            payeeID: nil,
            payeeName: "Corner Store",
            categoryID: categoryID,
            notes: nil,
            cleared: true,
            isTransfer: false
        )
    }

    private func isSuccess(_ outcome: TransactionEditorSubmissionCoordinator.Outcome) -> Bool {
        if case .succeeded = outcome { return true }
        return false
    }

    private func isProceed(_ preflight: TransactionEditorSubmissionCoordinator.Preflight) -> Bool {
        if case .proceed = preflight { return true }
        return false
    }

    // MARK: - create / update

    @Test func createSubmissionSucceedsAndReachesClean() async throws {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let repository = RecordingTransactionRepository()
        let draft = makeDraft()

        let preflight = coordinator.preflight(
            validation: .valid,
            draft: draft,
            editingIdentity: .creating
        )

        guard case .proceed(let identity, let resolvedDraft) = preflight else {
            Issue.record("expected .proceed"); return
        }
        #expect(identity == .creating)
        #expect(resolvedDraft == draft)

        let outcome = await coordinator.execute(
            editingIdentity: identity,
            draft: resolvedDraft,
            budgetID: "budget",
            repository: repository
        )

        #expect(isSuccess(outcome))
        #expect(coordinator.submissionState == .clean)
        #expect(!coordinator.isSubmitting)
        let savedDraft = try await repository.onlyDraft()
        #expect(savedDraft == draft)
    }

    @Test func updateSubmissionRoutesToUpdateRepositoryCall() async throws {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let repository = RecordingTransactionRepository()
        let draft = makeDraft()
        let identity: TransactionEditorSubmissionCoordinator.EditingIdentity = .updating(
            transactionID: "txn-1",
            originalAccountID: "checking",
            originalMonth: "2026-05"
        )

        let preflight = coordinator.preflight(
            validation: .valid,
            draft: draft,
            editingIdentity: identity
        )
        guard case .proceed(let resolvedIdentity, let resolvedDraft) = preflight else {
            Issue.record("expected .proceed"); return
        }
        #expect(resolvedIdentity == identity)

        let outcome = await coordinator.execute(
            editingIdentity: resolvedIdentity,
            draft: resolvedDraft,
            budgetID: "budget",
            repository: repository
        )
        #expect(isSuccess(outcome))
        #expect(coordinator.submissionState == .clean)
        #expect(await repository.draftCount() == 0)
        let update = try await repository.onlyUpdate()
        #expect(update.transactionID == "txn-1")
        #expect(update.originalAccountID == "checking")
        #expect(update.originalMonth == "2026-05")
    }

    // MARK: - callback sequencing

    @Test func submissionTransitionsThroughRefetching() async throws {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let repository = RecordingTransactionRepository(pauseAfterDidCreate: true)
        let draft = makeDraft()

        let task = Task {
            await coordinator.execute(
                editingIdentity: .creating,
                draft: draft,
                budgetID: "budget",
                repository: repository
            )
        }

        while await !repository.didCreateFinished() {
            await Task.yield()
        }

        // The didCreate callback has fired during the create call; the
        // coordinator should be mid-flight at `.refetching`.
        #expect(coordinator.submissionState == .refetching)
        #expect(coordinator.isSubmitting)

        await repository.resumeAfterDidCreate()

        let outcome = await task.value
        #expect(isSuccess(outcome))
        #expect(coordinator.submissionState == .clean)
    }

    // MARK: - duplicate submit rejection

    @Test func preflightRejectsAlreadySubmittingWhileInFlight() async throws {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let repository = RecordingTransactionRepository(pauseBeforeDidCreate: true)
        let draft = makeDraft()

        let firstSubmit = Task {
            await coordinator.execute(
                editingIdentity: .creating,
                draft: draft,
                budgetID: "budget",
                repository: repository
            )
        }

        while await !repository.isPausedBeforeDidCreate() {
            await Task.yield()
        }

        #expect(coordinator.submissionState == .submitting)

        // A second submission attempt while the first is in flight is rejected
        // before it touches the repository.
        let secondPreflight = coordinator.preflight(
            validation: .valid,
            draft: draft,
            editingIdentity: .creating
        )
        #expect(secondPreflight == .rejectedAlreadySubmitting)
        #expect(await repository.draftCount() == 1)

        await repository.resumeBeforeDidCreate()
        let outcome = await firstSubmit.value
        #expect(isSuccess(outcome))
        #expect(coordinator.submissionState == .clean)
    }

    // MARK: - failure / retry

    @Test func createFailureLeavesSubmissionRetryable() async {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let repository = RecordingTransactionRepository(createError: TestError("create failed"))
        let draft = makeDraft()

        let outcome = await coordinator.execute(
            editingIdentity: .creating,
            draft: draft,
            budgetID: "budget",
            repository: repository
        )

        #expect(outcome == .failed(message: "create failed"))
        #expect(coordinator.submissionState == .failed("create failed"))
        #expect(!coordinator.isSubmitting)
        // Retry: a fresh preflight proceeds because the state is no longer submitting.
        let retryPreflight = coordinator.preflight(
            validation: .valid,
            draft: draft,
            editingIdentity: .creating
        )
        #expect(isProceed(retryPreflight))
    }

    @Test func refreshFailureTransitionsThroughRefetchingToFailed() async {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let repository = RecordingTransactionRepository(refreshError: TestError("refresh failed"))
        let draft = makeDraft()

        let outcome = await coordinator.execute(
            editingIdentity: .creating,
            draft: draft,
            budgetID: "budget",
            repository: repository
        )

        // The didCreate callback fires (`.refetching`) before the refresh error
        // surfaces, so the final state is `.failed`.
        #expect(outcome == .failed(message: "refresh failed"))
        #expect(coordinator.submissionState == .failed("refresh failed"))
        #expect(!coordinator.isSubmitting)
    }

    // MARK: - cancellation / stale completion

    @Test func cancelMakesLateCompletionNoOp() async {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let repository = RecordingTransactionRepository(pauseBeforeDidCreate: true)
        let draft = makeDraft()

        let task = Task {
            await coordinator.execute(
                editingIdentity: .creating,
                draft: draft,
                budgetID: "budget",
                repository: repository
            )
        }

        while await !repository.isPausedBeforeDidCreate() {
            await Task.yield()
        }
        #expect(coordinator.submissionState == .submitting)

        // A budget switch / dismissal cancels the in-flight submission.
        coordinator.cancel()
        #expect(coordinator.submissionState == .draft)

        // Resuming the repository lets the create succeed and the late
        // `transitionToRefetching`/`complete` callbacks fire — but the
        // generation token no longer matches, so state stays `.draft`.
        await repository.resumeBeforeDidCreate()
        let outcome = await task.value
        #expect(isSuccess(outcome))
        #expect(coordinator.submissionState == .draft)
    }

    @Test func resetReturnsToDraftAndAllowsAFreshSubmission() async throws {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let repository = RecordingTransactionRepository()
        let draft = makeDraft()

        _ = await coordinator.execute(
            editingIdentity: .creating,
            draft: draft,
            budgetID: "budget",
            repository: repository
        )
        #expect(coordinator.submissionState == .clean)

        coordinator.reset()
        #expect(coordinator.submissionState == .draft)

        // A fresh submission proceeds after reset.
        let preflight = coordinator.preflight(
            validation: .valid,
            draft: draft,
            editingIdentity: .creating
        )
        #expect(isProceed(preflight))
    }

    // MARK: - preflight rejections (no state change except overflow)

    @Test func preflightRejectsSplitOverflowAndTransitionsToFailed() {
        let coordinator = TransactionEditorSubmissionCoordinator()

        let preflight = coordinator.preflight(
            validation: .overflow,
            draft: makeDraft(),
            editingIdentity: .creating
        )

        #expect(preflight == .rejectedSplitOverflow(message: "The split amounts are too large."))
        #expect(coordinator.submissionState == .failed("The split amounts are too large."))
    }

    @Test func preflightRejectsSplitMismatchWithoutStateChange() {
        let coordinator = TransactionEditorSubmissionCoordinator()
        let mismatch = TransactionSplitMismatch(transactionTotal: 1234, splitTotal: 1100)

        let preflight = coordinator.preflight(
            validation: .mismatch(mismatch),
            draft: makeDraft(),
            editingIdentity: .creating
        )

        #expect(preflight == .rejectedSplitMismatch)
        #expect(coordinator.submissionState == .draft)
    }

    @Test func preflightRejectsInvalidDraftWithoutStateChange() {
        let coordinator = TransactionEditorSubmissionCoordinator()

        let preflight = coordinator.preflight(
            validation: .valid,
            draft: nil,
            editingIdentity: .creating
        )

        #expect(preflight == .rejectedInvalidDraft)
        #expect(coordinator.submissionState == .draft)
    }

    @Test func preflightRejectsInvalidEditingIdentityWithoutStateChange() {
        let coordinator = TransactionEditorSubmissionCoordinator()

        let preflight = coordinator.preflight(
            validation: .valid,
            draft: makeDraft(),
            editingIdentity: nil
        )

        #expect(preflight == .rejectedInvalidEditingIdentity)
        #expect(coordinator.submissionState == .draft)
    }
}
