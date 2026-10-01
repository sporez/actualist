import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleCloseCoordinatorTests {
    @Test(arguments: [false, true])
    func pickerRefreshRetainsReviewAndBlocksStaleConfirmation(selectCategory: Bool) async throws {
        let repository = AccountLifecycleCloseCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        let initialAction = AccountLifecycleRequestedAction.close(
            destinationAccountID: "savings", categoryID: "old-category"
        )
        let initial = review(identity: checkingIdentity, action: initialAction)
        repository.reviewResult = initial
        await coordinator.loadReview(request: AccountLifecycleReviewRequest(
            budgetID: checkingIdentity.budgetID,
            accountID: checkingIdentity.accountID,
            requestedAction: initialAction
        ), repository: repository)?.value
        #expect(coordinator.canConfirmReview)

        repository.suspendReview = true
        let operation = try #require(selectCategory
            ? coordinator.selectCloseCategory("new-category", repository: repository)
            : coordinator.selectCloseDestination("other-account", repository: repository))
        do {
            try await repository.waitForReviewStart()
        } catch {
            coordinator.cancel()
            repository.finishReview(with: .failure(CancellationError()))
            await operation.value
            throw error
        }
        let expectedAction = AccountLifecycleRequestedAction.close(
            destinationAccountID: selectCategory ? "savings" : "other-account",
            categoryID: selectCategory ? "new-category" : nil
        )
        #expect(repository.lastReviewRequest?.requestedAction == expectedAction)
        #expect(coordinator.review == initial)
        #expect(coordinator.isRefreshingReview)
        #expect(!coordinator.isSubmitting)
        #expect(AccountLifecyclePresentation.mutationSheet(for: coordinator.state) == .review)
        #expect(!coordinator.canConfirmReview)
        #expect(coordinator.confirmReview(repository: repository) { _, _ in } == nil)
        #expect(coordinator.selectCloseDestination("ignored", repository: repository) == nil)
        #expect(coordinator.selectCloseCategory("ignored", repository: repository) == nil)
        #expect(repository.closeCalls == 0)

        let refreshed = review(identity: checkingIdentity, action: expectedAction)
        repository.finishReview(with: .success(refreshed))
        await operation.value
        #expect(coordinator.review == refreshed)
        #expect(!coordinator.isRefreshingReview)
        #expect(coordinator.canConfirmReview)
    }

    @Test(arguments: ["cancel", "context", "privacy", "replacement"])
    func latePickerRefreshCannotRestoreObsoleteReview(invalidation: String) async throws {
        let repository = AccountLifecycleCloseCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        repository.reviewResult = review(identity: checkingIdentity)
        await coordinator.loadReview(request: request(identity: checkingIdentity), repository: repository)?.value
        repository.suspendReview = true
        let operation = try #require(coordinator.selectCloseDestination("savings", repository: repository))
        do {
            try await repository.waitForReviewStart()
        } catch {
            coordinator.cancel()
            repository.finishReview(with: .failure(CancellationError()))
            await operation.value
            throw error
        }
        switch invalidation {
        case "context": coordinator.contextDidChange(to: savingsIdentity)
        case "privacy": coordinator.updatePrivacyMode(true)
        case "replacement":
            let replacement = AccountLifecycleCloseCoordinatorRepository()
            replacement.reviewResult = review(identity: checkingIdentity)
            await coordinator.loadReview(request: request(identity: checkingIdentity), repository: replacement)?.value
        default: coordinator.cancel()
        }
        let expectedState = coordinator.state
        repository.finishReview(with: .success(review(
            identity: checkingIdentity,
            action: .close(destinationAccountID: "savings", categoryID: nil)
        )))
        await operation.value
        #expect(coordinator.state == expectedState)
        #expect(!coordinator.isRefreshingReview)
    }

    @Test func failedPickerRefreshRequiresRetryOfNewSelection() async throws {
        let repository = AccountLifecycleCloseCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        repository.reviewResult = review(identity: checkingIdentity)
        await coordinator.loadReview(request: request(identity: checkingIdentity), repository: repository)?.value
        repository.reviewError = AccountLifecycleCommandError.accountNotFound
        let operation = try #require(coordinator.selectCloseDestination("savings", repository: repository))
        await operation.value
        #expect(coordinator.review == nil)
        #expect(!coordinator.canConfirmReview)
        #expect(coordinator.errorMessage == AccountLifecycleCommandError.accountNotFound.localizedDescription)
        #expect(AccountLifecyclePresentation.mutationSheet(for: coordinator.state) == .review)

        let action = AccountLifecycleRequestedAction.close(destinationAccountID: "savings", categoryID: nil)
        repository.reviewError = nil
        repository.reviewResult = review(identity: checkingIdentity, action: action)
        let retry = try #require(coordinator.retry(repository: repository))
        await retry.value
        #expect(repository.lastReviewRequest?.requestedAction == action)
        #expect(coordinator.review?.identity.action == action)
    }

    @Test func loadingAnotherAccountDoesNotRetainPreviousAccountReview() async {
        let repository = AccountLifecycleCloseCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        repository.reviewResult = review(identity: checkingIdentity)
        await coordinator.loadReview(request: request(identity: checkingIdentity), repository: repository)?.value
        repository.reviewResult = review(identity: savingsIdentity)
        let operation = coordinator.loadReview(request: request(identity: savingsIdentity), repository: repository)
        #expect(coordinator.review == nil)
        #expect(!coordinator.isRefreshingReview)
        await operation?.value
        #expect(coordinator.review?.identity.accountID == savingsIdentity.accountID)
    }

    @Test func duplicateConfirmationStartsOneCommitAndForwardsExactIdentity() async throws {
        let repository = AccountLifecycleCloseCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        let reviewed = review(identity: checkingIdentity)
        repository.reviewResult = reviewed
        let reviewTask = try #require(coordinator.loadReview(
            request: request(identity: checkingIdentity), repository: repository
        ))
        await reviewTask.value

        var committed: (AccountLifecycleIdentity, AccountLifecycleOutcome)?
        let operation = try #require(coordinator.confirmReview(repository: repository) {
            committed = ($0, $1)
        })
        #expect(coordinator.confirmReview(repository: repository) { _, _ in } == nil)
        do {
            try await repository.waitForCloseStart()
        } catch {
            coordinator.cancel()
            repository.releaseClose()
            await operation.value
            throw error
        }
        #expect(repository.closeCalls == 1)

        let result = outcome(accountID: checkingIdentity.accountID)
        repository.finishClose(with: .applied(result))
        await operation.value

        #expect(committed?.0 == checkingIdentity)
        #expect(committed?.1 == result)
    }

    @Test func cancellationRejectsACompletedCloseResult() async throws {
        let repository = AccountLifecycleCloseCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        repository.reviewResult = review(identity: checkingIdentity)
        let reviewTask = try #require(coordinator.loadReview(
            request: request(identity: checkingIdentity), repository: repository
        ))
        await reviewTask.value
        var commitCount = 0
        let operation = try #require(coordinator.confirmReview(repository: repository) { _, _ in
            commitCount += 1
        })
        do {
            try await repository.waitForCloseStart()
        } catch {
            coordinator.cancel()
            repository.releaseClose()
            await operation.value
            throw error
        }

        coordinator.cancel()
        repository.finishClose(with: .applied(outcome(accountID: checkingIdentity.accountID)))
        await operation.value

        #expect(coordinator.state == .idle)
        #expect(commitCount == 0)
    }

    @Test func lateOldSessionResultCannotReplaceANewerReview() async throws {
        let repository = AccountLifecycleCloseCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        repository.reviewResult = review(identity: checkingIdentity)
        let reviewTask = try #require(coordinator.loadReview(
            request: request(identity: checkingIdentity), repository: repository
        ))
        await reviewTask.value
        var commitCount = 0
        let oldOperation = try #require(coordinator.confirmReview(repository: repository) { _, _ in
            commitCount += 1
        })
        do {
            try await repository.waitForCloseStart()
        } catch {
            coordinator.cancel()
            repository.releaseClose()
            await oldOperation.value
            throw error
        }

        coordinator.contextDidChange(to: savingsIdentity)
        repository.reviewResult = review(identity: savingsIdentity)
        let replacementTask = try #require(coordinator.loadReview(
            request: request(identity: savingsIdentity), repository: repository
        ))
        await replacementTask.value

        repository.finishClose(with: .applied(outcome(accountID: checkingIdentity.accountID)))
        await oldOperation.value

        #expect(coordinator.review?.identity.accountID == savingsIdentity.accountID)
        #expect(commitCount == 0)
    }

    private func request(identity: AccountLifecycleIdentity) -> AccountLifecycleReviewRequest {
        AccountLifecycleReviewRequest(
            budgetID: identity.budgetID,
            accountID: identity.accountID,
            requestedAction: .close(destinationAccountID: nil, categoryID: nil)
        )
    }

    private func review(
        identity: AccountLifecycleIdentity,
        action: AccountLifecycleRequestedAction = .close(destinationAccountID: nil, categoryID: nil)
    ) -> AccountLifecycleReview {
        let account = AccountLifecycleAccount(
            id: identity.accountID,
            name: identity.accountID == "checking" ? "Checking" : "Savings",
            offBudget: false,
            isClosed: false,
            accountGroupID: "group"
        )
        return AccountLifecycleReview(
            identity: AccountLifecycleReviewIdentity(
                budgetID: identity.budgetID,
                accountID: identity.accountID,
                action: action,
                localDay: AccountLifecycleDay(isoDate: "2026-09-27", transactionDate: 20260927),
                sourceFacts: AccountLifecycleSourceFacts(
                    account: account,
                    liveBalance: 0,
                    liveTransactionCount: 1,
                    liveFamilyCount: 1,
                    pairedTransferCount: 0
                ),
                destinationFacts: nil,
                categoryFacts: nil,
                transactionGraphDigest: "graph-\(identity.accountID)",
                scheduleDigest: "schedule-\(identity.accountID)",
                bankLinkIdentity: nil
            ),
            account: account,
            liveBalance: 0,
            liveTransactionCount: 1,
            liveFamilyCount: 1,
            pairedTransferCount: 0,
            bankLink: nil,
            activeScheduleReferences: [],
            eligibleDestinations: [],
            eligibleCategories: [],
            resolvedAction: .closeAtZero,
            blockers: []
        )
    }

    private func outcome(accountID: String) -> AccountLifecycleOutcome {
        AccountLifecycleOutcome(
            operation: .close,
            account: AccountLifecycleAccount(
                id: accountID,
                name: accountID == "checking" ? "Checking" : "Savings",
                offBudget: false,
                isClosed: true,
                accountGroupID: "group"
            )
        )
    }

    private var checkingIdentity: AccountLifecycleIdentity {
        AccountLifecycleIdentity(budgetID: "budget", accountID: "checking")
    }

    private var savingsIdentity: AccountLifecycleIdentity {
        AccountLifecycleIdentity(budgetID: "new-budget", accountID: "savings")
    }
}

@MainActor
private final class AccountLifecycleCloseCoordinatorRepository: AccountLifecycleRepositoryProtocol {
    var reviewResult: AccountLifecycleReview?
    var reviewError: Error?
    var suspendReview = false
    private(set) var lastReviewRequest: AccountLifecycleReviewRequest?
    private(set) var closeCalls = 0

    private let closeStarted = TestLatch()
    private var closeContinuation: CheckedContinuation<AccountLifecycleCommitResult, Never>?
    private let reviewStarted = TestLatch()
    private var reviewContinuation: CheckedContinuation<AccountLifecycleReview, any Error>?

    func accountLifecycleReview(
        request: AccountLifecycleReviewRequest
    ) async throws -> AccountLifecycleReview {
        lastReviewRequest = request
        if let reviewError { throw reviewError }
        if suspendReview {
            // Deliberately ignore cancellation so tests can release and await late results.
            return try await withCheckedThrowingContinuation { continuation in
                reviewContinuation = continuation
                reviewStarted.trip()
            }
        }
        guard let reviewResult else {
            throw AccountLifecycleCommandError.invalidPreparedMutation
        }
        return reviewResult
    }

    func waitForReviewStart() async throws {
        try await waitForStart(reviewStarted)
    }

    func finishReview(with result: Result<AccountLifecycleReview, any Error>) {
        reviewContinuation?.resume(with: result)
        reviewContinuation = nil
    }

    func renameAccountAndRefresh(
        budgetID: String,
        command: AccountRenameCommand
    ) async throws -> AccountLifecycleCommitResult {
        throw AccountLifecycleCommandError.invalidPreparedMutation
    }

    func reopenAccountAndRefresh(
        budgetID: String,
        command: AccountReopenCommand
    ) async throws -> AccountLifecycleCommitResult {
        throw AccountLifecycleCommandError.invalidPreparedMutation
    }

    func commitAccountLifecycleAndRefresh(
        reviewed: AccountLifecycleReview
    ) async throws -> AccountLifecycleCommitResult {
        closeCalls += 1
        return await withCheckedContinuation { continuation in
            closeContinuation = continuation
            closeStarted.trip()
        }
    }

    func waitForCloseStart() async throws {
        try await waitForStart(closeStarted)
    }

    private func waitForStart(_ latch: TestLatch) async throws {
        try await withTimeLimit(
            .seconds(10),
            timeoutError: AccountLifecycleCloseCoordinatorTimeout()
        ) {
            try await withTaskCancellationHandler {
                await latch.wait()
                try Task.checkCancellation()
            } onCancel: {
                latch.trip()
            }
        }
    }

    func finishClose(with result: AccountLifecycleCommitResult) {
        closeContinuation?.resume(returning: result)
        closeContinuation = nil
    }

    func releaseClose() {
        finishClose(with: .noChange(AccountLifecycleOutcome(
            operation: .close,
            account: AccountLifecycleAccount(
                id: "released",
                name: "Released",
                offBudget: false,
                isClosed: true,
                accountGroupID: nil
            )
        )))
    }
}

private struct AccountLifecycleCloseCoordinatorTimeout: LocalizedError {
    var errorDescription: String? { "Timed out waiting for an account review or close submission." }
}
