import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountReconciliationCoordinatorTests {
    @Test func startLoadsTargetFromClearedAndCanUseLastSyncedBalance() async throws {
        let repository = ReconciliationCoordinatorRepository(
            snapshots: [snapshot(cleared: 12_345, synced: 15_000)]
        )
        let coordinator = AccountReconciliationCoordinator()

        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { coordinator.targetEntry != nil }

        #expect(coordinator.targetEntry?.input.text == "123.45")
        coordinator.useLastSyncedBalance()
        #expect(coordinator.targetEntry?.input.text == "150.00")
        coordinator.confirmTarget(locale: Locale(identifier: "en_US"))
        #expect(coordinator.activeSession?.targetBalance == 15_000)
        #expect(!coordinator.presentsTargetSheet)
    }

    @Test func invalidTargetStaysInEntryWithPreparedMessage() async {
        let repository = ReconciliationCoordinatorRepository(snapshots: [snapshot(cleared: 0)])
        let coordinator = AccountReconciliationCoordinator()
        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { coordinator.targetEntry != nil }

        coordinator.updateTargetText("12.345")
        coordinator.confirmTarget(locale: Locale(identifier: "en_US"))

        #expect(coordinator.activeSession == nil)
        #expect(
            coordinator.targetPresentation(privacyModeEnabled: false)?.validationMessage
                == "This balance has more decimal places than the budget currency supports."
        )
    }

    @Test func sheetDismissalCancelsEntryButNotAConfirmedSession() async {
        let repository = ReconciliationCoordinatorRepository(
            snapshots: [snapshot(cleared: 1_000), snapshot(cleared: 1_000)]
        )
        let coordinator = AccountReconciliationCoordinator()
        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { coordinator.targetEntry != nil }

        coordinator.targetSheetDismissed()
        #expect(coordinator.state == .idle)

        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { coordinator.targetEntry != nil }
        coordinator.confirmTarget(locale: Locale(identifier: "en_US"))
        coordinator.targetSheetDismissed()

        #expect(coordinator.activeSession?.targetBalance == 1_000)
    }

    @Test func adjustmentSerializesDuplicateIntentAndKeepsFreshDifference() async {
        let repository = ReconciliationCoordinatorRepository(snapshots: [snapshot(cleared: 1_000)])
        repository.suspendsAdjustment = true
        let coordinator = AccountReconciliationCoordinator()
        var mutationCount = 0
        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { coordinator.targetEntry != nil }
        coordinator.updateTargetText("20.00")
        coordinator.confirmTarget(locale: Locale(identifier: "en_US"))

        coordinator.createAdjustment(repository: repository) { mutationCount += 1 }
        coordinator.createAdjustment(repository: repository) { mutationCount += 1 }
        await waitUntil { repository.adjustmentCalls == 1 }

        repository.finishAdjustment(
            with: mutationResult(snapshot: snapshot(cleared: 1_700), changed: true)
        )
        await waitUntil { coordinator.submittingAction == nil }

        #expect(repository.adjustmentCalls == 1)
        #expect(mutationCount == 1)
        #expect(coordinator.activeSession?.targetBalance == 2_000)
        #expect(coordinator.activeSession?.snapshot.clearedBalance == 1_700)
        #expect(
            coordinator.panelPresentation(privacyModeEnabled: false)?.differenceText
                == BudgetCurrency.usd.formatted(300)
        )
    }

    @Test func ruleDeletedAdjustmentDoesNotPublishMutation() async {
        let repository = ReconciliationCoordinatorRepository(snapshots: [snapshot(cleared: 1_000)])
        repository.adjustmentResult = mutationResult(
            snapshot: snapshot(cleared: 1_000),
            changed: false
        )
        let coordinator = AccountReconciliationCoordinator()
        var mutationCount = 0
        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { coordinator.targetEntry != nil }
        coordinator.updateTargetText("20.00")
        coordinator.confirmTarget(locale: Locale(identifier: "en_US"))

        coordinator.createAdjustment(repository: repository) { mutationCount += 1 }
        await waitUntil { coordinator.submittingAction == nil }

        #expect(mutationCount == 0)
        #expect(coordinator.activeSession?.snapshot.clearedBalance == 1_000)
    }

    @Test func balanceChangeRefreshesSessionAndKeepsRetryableFailure() async {
        let repository = ReconciliationCoordinatorRepository(
            snapshots: [snapshot(cleared: 1_000), snapshot(cleared: 900)]
        )
        repository.finishError = AccountReconciliationCommandError.balanceChanged
        let coordinator = AccountReconciliationCoordinator()
        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { coordinator.targetEntry != nil }
        coordinator.confirmTarget(locale: Locale(identifier: "en_US"))

        coordinator.lockTransactions(repository: repository) {}
        await waitUntil { coordinator.activeErrorMessage != nil }

        #expect(coordinator.activeSession?.snapshot.clearedBalance == 900)
        #expect(coordinator.activeErrorMessage == "The cleared balance changed. Review the new difference before locking.")
        #expect(coordinator.panelPresentation(privacyModeEnabled: false)?.primaryAction == .createAdjustment)
    }

    @Test func successfulLockAndExitCloseTheWorkflow() async {
        let lockRepository = ReconciliationCoordinatorRepository(snapshots: [snapshot(cleared: 1_000)])
        let lockCoordinator = AccountReconciliationCoordinator()
        var lockMutationCount = 0
        lockCoordinator.start(identity: identity, currency: .usd, repository: lockRepository)
        await waitUntil { lockCoordinator.targetEntry != nil }
        lockCoordinator.confirmTarget(locale: Locale(identifier: "en_US"))
        lockCoordinator.lockTransactions(repository: lockRepository) { lockMutationCount += 1 }
        await waitUntil { lockCoordinator.state == .idle }
        #expect(lockMutationCount == 1)

        let exitRepository = ReconciliationCoordinatorRepository(snapshots: [snapshot(cleared: 1_000)])
        let exitCoordinator = AccountReconciliationCoordinator()
        exitCoordinator.start(identity: identity, currency: .usd, repository: exitRepository)
        await waitUntil { exitCoordinator.targetEntry != nil }
        exitCoordinator.updateTargetText("20.00")
        exitCoordinator.confirmTarget(locale: Locale(identifier: "en_US"))
        exitCoordinator.exit(repository: exitRepository) {}
        await waitUntil { exitCoordinator.state == .idle }
        #expect(exitRepository.exitCalls == 1)
    }

    @Test func cancellationDropsACompletionThatIgnoresTaskCancellation() async {
        let repository = ReconciliationCoordinatorRepository(snapshots: [])
        repository.suspendsSnapshot = true
        let coordinator = AccountReconciliationCoordinator()
        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { repository.hasPendingSnapshot }

        coordinator.cancel()
        repository.finishSnapshot(with: snapshot(cleared: 5_000))
        await Task.yield()

        #expect(coordinator.state == .idle)
        #expect(coordinator.targetEntry == nil)
    }

    @Test func budgetOrAccountIdentityChangeCancelsActiveSession() async {
        let repository = ReconciliationCoordinatorRepository(snapshots: [snapshot(cleared: 1_000)])
        let coordinator = AccountReconciliationCoordinator()
        coordinator.start(identity: identity, currency: .usd, repository: repository)
        await waitUntil { coordinator.targetEntry != nil }
        coordinator.confirmTarget(locale: Locale(identifier: "en_US"))

        coordinator.reconcileContext(AccountReconciliationIdentity(
            budgetID: "other-budget",
            accountID: "checking"
        ))

        #expect(coordinator.state == .idle)
    }

    @Test func privacyPresentationPreservesDifferenceRelationshipAndDisablesWrites() {
        let session = AccountReconciliationSession(
            identity: identity,
            targetBalance: 2_000,
            snapshot: snapshot(cleared: 1_000)
        )
        let presentation = AccountReconciliationPresentation.panel(
            session: session,
            submittingAction: nil,
            errorMessage: nil,
            currency: .usd,
            privacyModeEnabled: true
        )
        let privateCleared = PrivacyDisplay.amount(
            1_000,
            seed: "reconciliation-panel-cleared-checking",
            currency: .usd,
            maximumDollars: 1_200
        )
        let privateDifference = PrivacyDisplay.amount(
            1_000,
            seed: "reconciliation-panel-difference-checking",
            currency: .usd,
            maximumDollars: 250
        )

        #expect(presentation.clearedBalanceText == BudgetCurrency.usd.formatted(privateCleared))
        #expect(presentation.differenceText == BudgetCurrency.usd.formatted(privateDifference))
        #expect(presentation.targetText == BudgetCurrency.usd.formatted(privateCleared + privateDifference))
        #expect(presentation.isPrivacyProtected)

        let entry = AccountReconciliationTargetEntry(
            identity: identity,
            snapshot: snapshot(cleared: 1_000, synced: 2_500),
            input: AccountReconciliationAmountInput(minorUnits: 1_000, currency: .usd),
            validationMessage: nil
        )
        let target = AccountReconciliationPresentation.target(
            entry: entry,
            currency: .usd,
            privacyModeEnabled: true,
            locale: Locale(identifier: "en_US")
        )
        #expect(!target.canContinue)
        #expect(target.isPrivacyProtected)
        #expect(target.lastReconciledText == "Hidden while Sample Values is on")
        #expect(target.amountText != BudgetCurrency.usd.formatted(1_000))
    }

    private let identity = AccountReconciliationIdentity(
        budgetID: "budget",
        accountID: "checking"
    )

    private func snapshot(
        cleared: Int,
        synced: Int? = nil
    ) -> AccountReconciliationSnapshot {
        AccountReconciliationSnapshot(
            accountID: "checking",
            accountName: "Checking",
            workingBalance: cleared,
            clearedBalance: cleared,
            lastSyncedBalance: synced,
            lastReconciledMilliseconds: 1_789_344_000_000,
            capability: .available
        )
    }

    private func mutationResult(
        snapshot: AccountReconciliationSnapshot,
        changed: Bool
    ) -> AccountReconciliationMutationResult {
        AccountReconciliationMutationResult(
            snapshot: snapshot,
            changed: ChangedResources(
                accounts: changed ? ["checking"] : [],
                months: changed ? ["2026-09"] : [],
                transactions: changed ? ["adjustment"] : []
            )
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for reconciliation state")
    }
}

@MainActor
private final class ReconciliationCoordinatorRepository: AccountRepositoryProtocol {
    var snapshots: [AccountReconciliationSnapshot]
    var suspendsSnapshot = false
    var suspendsAdjustment = false
    var adjustmentResult: AccountReconciliationMutationResult?
    var finishResult: AccountReconciliationMutationResult?
    var exitResult: AccountReconciliationMutationResult?
    var finishError: Error?
    private(set) var adjustmentCalls = 0
    private(set) var finishCalls = 0
    private(set) var exitCalls = 0
    private var snapshotContinuation: CheckedContinuation<AccountReconciliationSnapshot, any Error>?
    private var adjustmentContinuation: CheckedContinuation<AccountReconciliationMutationResult, any Error>?

    init(snapshots: [AccountReconciliationSnapshot]) {
        self.snapshots = snapshots
    }

    var hasPendingSnapshot: Bool { snapshotContinuation != nil }

    func accountDisplays(budgetID: String) -> [AccountDisplay] { [] }
    func accountGroups(budgetID: String) -> [ActualAccountGroup] { [] }
    func accountGroupManagementEnabled(budgetID: String) -> Bool { false }
    func refreshAccountsWithBalances(budgetID: String) async throws {}

    func accountReconciliationSnapshot(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationSnapshot {
        if suspendsSnapshot {
            return try await withCheckedThrowingContinuation { snapshotContinuation = $0 }
        }
        return snapshots.removeFirst()
    }

    func createReconciliationAdjustmentAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult {
        adjustmentCalls += 1
        if suspendsAdjustment {
            return try await withCheckedThrowingContinuation { adjustmentContinuation = $0 }
        }
        return adjustmentResult ?? Self.result(accountID: accountID, cleared: targetBalance)
    }

    func finishReconciliationAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult {
        finishCalls += 1
        if let finishError { throw finishError }
        return finishResult ?? Self.result(accountID: accountID, cleared: targetBalance)
    }

    func exitReconciliationAndRefresh(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationMutationResult {
        exitCalls += 1
        return exitResult ?? Self.result(accountID: accountID, cleared: 0)
    }

    func unlockReconciledTransactionAndRefresh(
        budgetID: String,
        accountID: String,
        transactionID: String
    ) async throws -> AccountReconciliationMutationResult {
        Self.result(accountID: accountID, cleared: 0)
    }

    func finishSnapshot(with snapshot: AccountReconciliationSnapshot) {
        suspendsSnapshot = false
        snapshotContinuation?.resume(returning: snapshot)
        snapshotContinuation = nil
    }

    func finishAdjustment(with result: AccountReconciliationMutationResult) {
        suspendsAdjustment = false
        adjustmentContinuation?.resume(returning: result)
        adjustmentContinuation = nil
    }

    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {}
    func createAccountGroupAndRefresh(budgetID: String, name: String) async throws {}
    func renameAccountGroupAndRefresh(budgetID: String, groupID: String, name: String) async throws {}
    func deleteAccountGroupAndRefresh(budgetID: String, groupID: String) async throws {}
    func moveAccountToGroupAndRefresh(
        budgetID: String,
        accountID: String,
        groupID: String?
    ) async throws {}
    func moveAccountGroupAndRefresh(
        budgetID: String,
        groupID: String,
        beforeGroupID: String?
    ) async throws {}

    private static func result(
        accountID: String,
        cleared: Int
    ) -> AccountReconciliationMutationResult {
        AccountReconciliationMutationResult(
            snapshot: AccountReconciliationSnapshot(
                accountID: accountID,
                accountName: "Checking",
                workingBalance: cleared,
                clearedBalance: cleared,
                lastSyncedBalance: nil,
                lastReconciledMilliseconds: nil,
                capability: .available
            ),
            changed: ChangedResources(
                accounts: [accountID],
                months: [],
                transactions: []
            )
        )
    }
}
