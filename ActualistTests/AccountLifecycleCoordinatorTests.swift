import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountLifecycleCoordinatorTests {
    @Test func renameValidatesInputAndPublishesAppliedOutcome() async throws {
        let repository = LifecycleCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        var mutation: AccountLifecycleOutcome?
        coordinator.beginRename(
            identity: identity,
            account: openAccount,
            existingAccounts: [openAccount, savingsAccount]
        )

        coordinator.updateRenameName(" Savings ")
        coordinator.submitRename(repository: repository) { mutation = $0 }
        #expect(repository.renameCalls == 0)
        #expect(coordinator.renameDraft?.validationError == .duplicateName("Savings"))

        coordinator.updateRenameName(" Daily Spending ")
        coordinator.submitRename(repository: repository) { mutation = $0 }
        await ObservedTestState {
            if case .completed = coordinator.state { return true }
            return false
        }.wait()

        #expect(repository.renameCalls == 1)
        #expect(repository.lastRenameCommand?.newName == "Daily Spending")
        #expect(mutation?.account.name == "Daily Spending")
    }

    @Test func duplicateRenameIntentIsSerializedWhileRepositoryIsSuspended() async throws {
        let repository = LifecycleCoordinatorRepository()
        repository.suspendRename = true
        let coordinator = AccountLifecycleCoordinator()
        coordinator.beginRename(
            identity: identity,
            account: openAccount,
            existingAccounts: [openAccount]
        )
        coordinator.updateRenameName("Daily Spending")

        let operation = try #require(coordinator.submitRename(repository: repository) { _ in })
        coordinator.submitRename(repository: repository) { _ in }
        do {
            try await repository.waitForRenameStart()
        } catch {
            coordinator.cancel()
            repository.releasePendingResponses()
            await operation.value
            throw error
        }
        #expect(repository.renameCalls == 1)
        #expect(coordinator.isSubmitting)

        repository.finishRename(with: .applied(outcome(
            operation: .rename,
            account: AccountLifecycleAccount(
                id: "checking",
                name: "Daily Spending",
                offBudget: false,
                isClosed: false,
                accountGroupID: "group"
            )
        )))
        await operation.value
    }

    @Test func renameMutationCallbackCanCancelCompletedWorkflow() async {
        let repository = LifecycleCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        coordinator.beginRename(
            identity: identity,
            account: openAccount,
            existingAccounts: [openAccount]
        )
        coordinator.updateRenameName("Daily Spending")

        let operation = coordinator.submitRename(repository: repository) { _ in
            coordinator.cancel()
        }
        #expect(operation != nil)
        await operation?.value

        #expect(coordinator.state == .idle)
    }

    @Test func renameMutationCallbackCanBeginNewWorkflow() async {
        let repository = LifecycleCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        coordinator.beginRename(
            identity: identity,
            account: openAccount,
            existingAccounts: [openAccount]
        )
        coordinator.updateRenameName("Daily Spending")

        let operation = coordinator.submitRename(repository: repository) { _ in
            coordinator.beginReopen(identity: self.identity, account: self.closedAccount)
        }
        #expect(operation != nil)
        await operation?.value

        #expect(coordinator.state == .reopening(AccountReopenSession(
            identity: identity,
            account: closedAccount
        )))
    }

    @Test func peerCompletedReopenCompletesWithoutPublishingMutation() async throws {
        let repository = LifecycleCoordinatorRepository()
        repository.reopenResult = .noChange(outcome(operation: .reopen, account: openAccount))
        let coordinator = AccountLifecycleCoordinator()
        var mutationCount = 0
        coordinator.beginReopen(identity: identity, account: closedAccount)

        coordinator.confirmReopen(repository: repository) { _ in mutationCount += 1 }
        await ObservedTestState {
            if case .completed = coordinator.state { return true }
            return false
        }.wait()

        #expect(repository.reopenCalls == 1)
        #expect(repository.lastReopenCommand == AccountReopenCommand(
            accountID: "checking",
            expectedClosed: true
        ))
        #expect(mutationCount == 0)
    }

    @Test func reopenMutationCallbackCanCancelCompletedWorkflow() async {
        let repository = LifecycleCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        coordinator.beginReopen(identity: identity, account: closedAccount)

        let operation = coordinator.confirmReopen(repository: repository) { _ in
            coordinator.cancel()
        }
        #expect(operation != nil)
        await operation?.value

        #expect(coordinator.state == .idle)
    }

    @Test func reopenMutationCallbackCanBeginNewWorkflow() async {
        let repository = LifecycleCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator()
        coordinator.beginReopen(identity: identity, account: closedAccount)

        let operation = coordinator.confirmReopen(repository: repository) { _ in
            coordinator.beginRename(
                identity: self.identity,
                account: self.openAccount,
                existingAccounts: [self.openAccount]
            )
        }
        #expect(operation != nil)
        await operation?.value

        #expect(coordinator.renameDraft?.identity == identity)
    }

    @Test func reviewLoadAndRetryKeepOneExplicitRecoveryState() async throws {
        let repository = LifecycleCoordinatorRepository()
        repository.reviewError = AccountLifecycleCommandError.missingTransactionSchema
        let coordinator = AccountLifecycleCoordinator()
        let request = AccountLifecycleReviewRequest(
            budgetID: "budget",
            accountID: "checking",
            requestedAction: .close(destinationAccountID: nil, categoryID: nil)
        )

        coordinator.loadReview(request: request, repository: repository)
        await ObservedTestState { coordinator.errorMessage != nil }.wait()
        #expect(coordinator.errorMessage == "Account maintenance is not available for this budget file.")

        repository.reviewError = nil
        repository.reviewResult = review(request: request)
        coordinator.retry(repository: repository)
        await ObservedTestState { coordinator.review != nil }.wait()

        #expect(repository.reviewCalls == 2)
        #expect(coordinator.review?.identity.accountID == "checking")
    }

    @Test func accountOrBudgetContextChangeCancelsPresentedWorkflow() {
        let coordinator = AccountLifecycleCoordinator()
        coordinator.beginReopen(identity: identity, account: closedAccount)

        coordinator.contextDidChange(to: AccountLifecycleIdentity(
            budgetID: "other-budget",
            accountID: "checking"
        ))

        #expect(coordinator.state == .idle)
    }

    @Test func suspendedLateRenameSuccessCannotRestoreChangedContext() async throws {
        let repository = LifecycleCoordinatorRepository()
        repository.suspendRename = true
        let coordinator = AccountLifecycleCoordinator()
        var mutationCount = 0
        coordinator.beginRename(
            identity: identity,
            account: openAccount,
            existingAccounts: [openAccount]
        )
        coordinator.updateRenameName("Daily Spending")
        let operation = try #require(coordinator.submitRename(repository: repository) { _ in
            mutationCount += 1
        })
        do {
            try await repository.waitForRenameStart()
        } catch {
            coordinator.cancel()
            repository.releasePendingResponses()
            await operation.value
            throw error
        }

        coordinator.contextDidChange(to: AccountLifecycleIdentity(
            budgetID: "other-budget",
            accountID: "checking"
        ))
        repository.finishRename(with: .applied(outcome(
            operation: .rename,
            account: AccountLifecycleAccount(
                id: "checking",
                name: "Daily Spending",
                offBudget: false,
                isClosed: false,
                accountGroupID: "group"
            )
        )))
        await operation.value

        #expect(coordinator.state == .idle)
        #expect(mutationCount == 0)
    }

    @Test func sampleValuesRefusesWorkflowBeginsAndSubmission() async {
        let repository = LifecycleCoordinatorRepository()
        let coordinator = AccountLifecycleCoordinator(isPrivacyModeEnabled: true)
        let request = AccountLifecycleReviewRequest(
            budgetID: "budget",
            accountID: "checking",
            requestedAction: .close(destinationAccountID: nil, categoryID: nil)
        )

        coordinator.beginRename(
            identity: identity,
            account: openAccount,
            existingAccounts: [openAccount]
        )
        coordinator.beginReopen(identity: identity, account: closedAccount)
        coordinator.loadReview(request: request, repository: repository)
        let renameOperation = coordinator.submitRename(repository: repository) { _ in }
        let reopenOperation = coordinator.confirmReopen(repository: repository) { _ in }

        #expect(coordinator.state == .idle)
        #expect(renameOperation == nil)
        #expect(reopenOperation == nil)
        #expect(repository.renameCalls == 0)
        #expect(repository.reopenCalls == 0)
        #expect(repository.reviewCalls == 0)
    }

    @Test func enablingSampleValuesCancelsSuspendedMutationAndRejectsLateSuccess() async throws {
        let repository = LifecycleCoordinatorRepository()
        repository.suspendReopen = true
        let coordinator = AccountLifecycleCoordinator()
        var mutationCount = 0
        coordinator.beginReopen(identity: identity, account: closedAccount)
        let operation = try #require(coordinator.confirmReopen(repository: repository) { _ in
            mutationCount += 1
        })
        do {
            try await repository.waitForReopenStart()
        } catch {
            coordinator.cancel()
            repository.releasePendingResponses()
            await operation.value
            throw error
        }

        coordinator.updatePrivacyMode(true)
        repository.finishReopen(with: .applied(outcome(
            operation: .reopen,
            account: openAccount
        )))
        await operation.value

        #expect(coordinator.isPrivacyModeEnabled)
        #expect(coordinator.state == .idle)
        #expect(coordinator.reopenSession == nil)
        #expect(mutationCount == 0)
    }

    private let identity = AccountLifecycleIdentity(budgetID: "budget", accountID: "checking")

    private var openAccount: AccountLifecycleAccount {
        AccountLifecycleAccount(
            id: "checking",
            name: "Checking",
            offBudget: false,
            isClosed: false,
            accountGroupID: "group"
        )
    }

    private var closedAccount: AccountLifecycleAccount {
        AccountLifecycleAccount(
            id: "checking",
            name: "Checking",
            offBudget: false,
            isClosed: true,
            accountGroupID: "group"
        )
    }

    private var savingsAccount: AccountLifecycleAccount {
        AccountLifecycleAccount(
            id: "savings",
            name: "Savings",
            offBudget: false,
            isClosed: true,
            accountGroupID: nil
        )
    }

    private func outcome(
        operation: AccountLifecycleOperation,
        account: AccountLifecycleAccount
    ) -> AccountLifecycleOutcome {
        AccountLifecycleOutcome(operation: operation, account: account)
    }

    private func review(request: AccountLifecycleReviewRequest) -> AccountLifecycleReview {
        AccountLifecycleReview(
            identity: AccountLifecycleReviewIdentity(
                budgetID: request.budgetID,
                accountID: request.accountID,
                action: request.requestedAction,
                sourceFacts: AccountLifecycleSourceFacts(
                    account: openAccount,
                    liveBalance: 0,
                    liveTransactionCount: 1,
                    liveFamilyCount: 1,
                    pairedTransferCount: 0
                ),
                destinationFacts: nil,
                categoryFacts: nil,
                transactionGraphDigest: "graph",
                scheduleDigest: "schedule",
                bankLinkIdentity: nil
            ),
            account: openAccount,
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
}

@MainActor
private final class LifecycleCoordinatorRepository: AccountLifecycleRepositoryProtocol {
    var suspendRename = false
    var suspendReopen = false
    var renameResult: AccountLifecycleCommitResult?
    var reopenResult: AccountLifecycleCommitResult?
    var reviewResult: AccountLifecycleReview?
    var reviewError: Error?
    private(set) var renameCalls = 0
    private(set) var reopenCalls = 0
    private(set) var reviewCalls = 0
    private(set) var lastRenameCommand: AccountRenameCommand?
    private(set) var lastReopenCommand: AccountReopenCommand?

    private var renameContinuation: CheckedContinuation<AccountLifecycleCommitResult, any Error>?
    private var reopenContinuation: CheckedContinuation<AccountLifecycleCommitResult, any Error>?
    private let renameStarted = TestLatch()
    private let reopenStarted = TestLatch()

    func accountLifecycleReview(
        request: AccountLifecycleReviewRequest
    ) async throws -> AccountLifecycleReview {
        reviewCalls += 1
        if let reviewError { throw reviewError }
        guard let reviewResult else {
            throw AccountLifecycleCommandError.invalidPreparedMutation
        }
        return reviewResult
    }

    func renameAccountAndRefresh(
        budgetID: String,
        command: AccountRenameCommand
    ) async throws -> AccountLifecycleCommitResult {
        renameCalls += 1
        lastRenameCommand = command
        renameStarted.trip()
        if suspendRename {
            // Intentionally ignores cancellation until the test releases the
            // response so late-result rejection remains under test.
            return try await withCheckedThrowingContinuation { renameContinuation = $0 }
        }
        return renameResult ?? .applied(AccountLifecycleOutcome(
            operation: .rename,
            account: AccountLifecycleAccount(
                id: command.accountID,
                name: command.newName,
                offBudget: false,
                isClosed: false,
                accountGroupID: "group"
            )
        ))
    }

    func reopenAccountAndRefresh(
        budgetID: String,
        command: AccountReopenCommand
    ) async throws -> AccountLifecycleCommitResult {
        reopenCalls += 1
        lastReopenCommand = command
        reopenStarted.trip()
        if suspendReopen {
            // Intentionally ignores cancellation until the test releases the
            // response so late-result rejection remains under test.
            return try await withCheckedThrowingContinuation { reopenContinuation = $0 }
        }
        return reopenResult ?? .applied(AccountLifecycleOutcome(
            operation: .reopen,
            account: AccountLifecycleAccount(
                id: command.accountID,
                name: "Checking",
                offBudget: false,
                isClosed: false,
                accountGroupID: "group"
            )
        ))
    }

    func waitForRenameStart() async throws {
        try await waitForLifecycleLatch(renameStarted, description: "rename request")
    }

    func finishRename(with result: AccountLifecycleCommitResult) {
        suspendRename = false
        renameContinuation?.resume(returning: result)
        renameContinuation = nil
    }

    func waitForReopenStart() async throws {
        try await waitForLifecycleLatch(reopenStarted, description: "reopen request")
    }

    func finishReopen(with result: AccountLifecycleCommitResult) {
        suspendReopen = false
        reopenContinuation?.resume(returning: result)
        reopenContinuation = nil
    }

    func releasePendingResponses() {
        suspendRename = false
        suspendReopen = false
        renameContinuation?.resume(throwing: CancellationError())
        renameContinuation = nil
        reopenContinuation?.resume(throwing: CancellationError())
        reopenContinuation = nil
    }
}

private struct LifecycleLatchTimeout: LocalizedError {
    let description: String

    var errorDescription: String? {
        "Timed out waiting for \(description)."
    }
}

private func waitForLifecycleLatch(
    _ latch: TestLatch,
    description: String
) async throws {
    try await withTimeLimit(
        .seconds(10),
        timeoutError: LifecycleLatchTimeout(description: description)
    ) {
        try await withTaskCancellationHandler {
            await latch.wait()
            try Task.checkCancellation()
        } onCancel: {
            latch.trip()
        }
    }
}
