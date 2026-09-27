import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleCloseCoordinatorTests {
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

    private func review(identity: AccountLifecycleIdentity) -> AccountLifecycleReview {
        let account = AccountLifecycleAccount(
            id: identity.accountID,
            name: identity.accountID == "checking" ? "Checking" : "Savings",
            offBudget: false,
            isClosed: false,
            accountGroupID: "group"
        )
        let request = request(identity: identity)
        return AccountLifecycleReview(
            identity: AccountLifecycleReviewIdentity(
                budgetID: identity.budgetID,
                accountID: identity.accountID,
                action: request.requestedAction,
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
    private(set) var closeCalls = 0

    private let closeStarted = TestLatch()
    private var closeContinuation: CheckedContinuation<AccountLifecycleCommitResult, Never>?

    func accountLifecycleReview(
        request: AccountLifecycleReviewRequest
    ) async throws -> AccountLifecycleReview {
        guard let reviewResult else {
            throw AccountLifecycleCommandError.invalidPreparedMutation
        }
        return reviewResult
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
        let latch = closeStarted
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
    var errorDescription: String? { "Timed out waiting for close submission." }
}
