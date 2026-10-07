import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountsViewModelTests {
    @Test(arguments: CancellationTestCase.allCases)
    func cancelledAccountLoadsAndEditsEndWithoutErrors(_ kind: CancellationTestCase) async {
        let repository = FakeAccountRepository()
        repository.loadError = kind.error
        repository.createError = kind.error
        let model = AccountsViewModel()
        await model.loadLocal(budgetID: "budget", hasCachedAccounts: false, repository: repository)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
        model.presentCreateGroup()
        model.groupEditorName = "Cash"
        #expect(await model.submitGroupEditor(budgetID: "budget", repository: repository) == false)
        #expect(!model.isSubmitting)
        #expect(model.errorMessage == nil)
        #expect(model.groupEditor == .create)
        let order = SettingsAccountOrderViewModel()
        await order.load(budgetID: "budget", repository: repository)
        #expect(!order.isLoading)
        #expect(order.errorMessage == nil)
        repository.loadError = LocalFirstError.invalidLocalWrite("Cannot load accounts.")
        await order.load(budgetID: "budget", repository: repository)
        #expect(order.errorMessage == repository.loadError?.localizedDescription)
    }

    @Test func accountOrderBucketsMirrorTheAccountsScreenAndSkipEmptyGroups() {
        func display(_ id: String, offbudget: Bool = false, groupID: String? = nil) -> AccountDisplay {
            AccountDisplay(
                account: ActualAccount(id: id, name: id, offbudget: offbudget, closed: false, accountGroupId: groupID),
                balance: 0
            )
        }
        let savings = ActualAccountGroup(id: "savings", name: "Savings", sortOrder: 16_384)
        let empty = ActualAccountGroup(id: "empty", name: "Empty", sortOrder: 32_768)
        let sections = AccountListLayout.sections(
            displays: [
                display("ally", groupID: "savings"),
                display("roth", offbudget: true, groupID: "savings"),
                display("house", offbudget: true)
            ],
            groups: [savings, empty],
            preferredIDs: []
        )

        let buckets = SettingsAccountOrderViewModel.buckets(from: sections)

        #expect(buckets.map(\.id) == ["budget-savings", "offBudget-ungrouped", "offBudget-savings"])
        #expect(buckets.map(\.sectionTitle) == ["Budget Accounts", "Off Budget", nil])
        #expect(buckets.map(\.groupName) == ["Savings", nil, "Savings"])
        #expect(buckets.map { $0.accounts.map(\.id) } == [["ally"], ["house"], ["roth"]])
    }

    @Test func submitCreateGroupClearsEditorAndRecordsTheName() async throws {
        let repository = FakeAccountRepository()
        let viewModel = AccountsViewModel()
        viewModel.presentCreateGroup()
        viewModel.groupEditorName = "Cash"

        let submitted = await viewModel.submitGroupEditor(
            budgetID: "group-1",
            repository: repository
        )

        #expect(submitted)
        #expect(viewModel.groupEditor == nil)
        #expect(repository.createdNames == ["Cash"])
    }

    @Test func submitDuplicateNameKeepsEditorAndSurfacesTheError() async throws {
        let repository = FakeAccountRepository()
        repository.createError = LocalFirstError.invalidLocalWrite(
            "An 'Cash' account group already exists."
        )
        let viewModel = AccountsViewModel()
        viewModel.presentCreateGroup()
        viewModel.groupEditorName = "Cash"

        let submitted = await viewModel.submitGroupEditor(
            budgetID: "group-1",
            repository: repository
        )

        #expect(!submitted)
        #expect(viewModel.groupEditor == .create)
        #expect(viewModel.errorMessage?.contains("already exists") == true)
    }

    @Test func deleteReviewCancelDoesNotWrite() async {
        let repository = FakeAccountRepository()
        let viewModel = AccountsViewModel()
        let group = ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 16_384)
        viewModel.presentDelete(
            group,
            displays: [
                AccountDisplay(
                    account: ActualAccount(
                        id: "checking",
                        name: "Checking",
                        offbudget: false,
                        closed: false,
                        accountGroupId: "cash"
                    ),
                    balance: 0
                )
            ]
        )

        viewModel.cancelDelete()
        await viewModel.confirmDelete(budgetID: "group-1", repository: repository)

        #expect(viewModel.deleteReview == nil)
        #expect(repository.deletedIDs.isEmpty)
    }

    @Test func budgetSwitchDropsInFlightEditorAndDeleteReview() async {
        let repository = FakeAccountRepository()
        let viewModel = AccountsViewModel()
        viewModel.presentCreateGroup()
        viewModel.groupEditorName = "Cash"
        viewModel.presentDelete(
            ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 16_384),
            displays: []
        )

        await viewModel.loadLocal(
            budgetID: "other-budget",
            hasCachedAccounts: true,
            repository: repository
        )

        #expect(viewModel.groupEditor == nil)
        #expect(viewModel.deleteReview == nil)
        #expect(viewModel.groupEditorName.isEmpty)
    }
    enum ParkedWrite: CaseIterable, Sendable {
        case createGroup, renameGroup, deleteGroup, moveAccount, moveGroup
    }

    private func startWrite(
        _ write: ParkedWrite,
        on viewModel: AccountsViewModel,
        repository: FakeAccountRepository
    ) -> Task<Void, Never> {
        let group = ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 16_384)
        let display = AccountDisplay(
            account: ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false, accountGroupId: nil),
            balance: 0
        )
        switch write {
        case .createGroup:
            viewModel.presentCreateGroup()
            viewModel.groupEditorName = "Cash"
            return Task { _ = await viewModel.submitGroupEditor(budgetID: "budget", repository: repository) }
        case .renameGroup:
            viewModel.presentRename(group)
            viewModel.groupEditorName = "Cash 2"
            return Task { _ = await viewModel.submitGroupEditor(budgetID: "budget", repository: repository) }
        case .deleteGroup:
            viewModel.presentDelete(group, displays: [])
            return Task { await viewModel.confirmDelete(budgetID: "budget", repository: repository) }
        case .moveAccount:
            return Task {
                await viewModel.moveAccount(display, toGroupID: "cash", budgetID: "budget", repository: repository)
            }
        case .moveGroup:
            return Task {
                await viewModel.moveGroup(group, beforeGroupID: nil, budgetID: "budget", repository: repository)
            }
        }
    }

    @Test(arguments: ParkedWrite.allCases)
    func budgetChangeDuringAWriteDoesNotLeaveTheModelBusy(_ write: ParkedWrite) async {
        let repository = FakeAccountRepository()
        let viewModel = AccountsViewModel()
        await viewModel.loadLocal(budgetID: "budget", hasCachedAccounts: true, repository: repository)
        let gate = repository.parkNextWrite()
        let task = startWrite(write, on: viewModel, repository: repository)
        await gate.entered.wait()
        #expect(viewModel.isSubmitting)

        await viewModel.loadLocal(budgetID: "other", hasCachedAccounts: true, repository: repository)
        #expect(!viewModel.isSubmitting)
        let revision = viewModel.contentRevision

        // A fresh edit for the new budget is not refused while the stale write is still parked.
        let callsBefore = repository.writeCalls.count
        await viewModel.moveGroup(
            ActualAccountGroup(id: "g", name: "G", sortOrder: 1),
            beforeGroupID: nil,
            budgetID: "other",
            repository: repository
        )
        #expect(repository.writeCalls.count == callsBefore + 1)

        gate.release.trip()
        await task.value
        #expect(!viewModel.isSubmitting)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.contentRevision == revision &+ 1) // only the new budget's own edit
        await viewModel.moveGroup(
            ActualAccountGroup(id: "g", name: "G", sortOrder: 1),
            beforeGroupID: nil,
            budgetID: "other",
            repository: repository
        )
        #expect(repository.writeCalls.count == callsBefore + 2)
    }

    @Test func addAccountResetWhileCreatingDoesNotAllowASecondCreate() async {
        let repository = FakeAccountRepository()
        let viewModel = AddAccountViewModel()
        viewModel.name = "Savings"
        let gate = repository.parkNextWrite()
        let first = Task { await viewModel.submit(budgetID: "budget", repository: repository) }
        await gate.entered.wait()

        viewModel.reset()
        #expect(viewModel.isSubmitting)
        viewModel.name = "Savings"
        #expect(await viewModel.submit(budgetID: "budget", repository: repository) == false)

        gate.release.trip()
        #expect(await first.value)
        #expect(repository.writeCalls == ["createAccount"])
        #expect(!viewModel.isSubmitting)
        #expect(viewModel.name.isEmpty)
    }

    @Test func supersededLoadFinishingLastDoesNotPublishItsErrorOrLoadingState() async {
        let repository = FakeAccountRepository()
        let gate = repository.parkNextLoad(failingWith: LocalFirstError.invalidLocalWrite("old budget failed"))
        let model = AccountsViewModel()

        let older = Task {
            await model.loadLocal(budgetID: "old", hasCachedAccounts: false, repository: repository)
        }
        let entered = await gate.entered.wait(timeout: .seconds(5), onTimeout: { gate.release.trip() })
        #expect(entered)
        await model.loadLocal(budgetID: "new", hasCachedAccounts: false, repository: repository)
        #expect(!model.isLoading)

        gate.release.trip()
        await older.value

        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }
}

@MainActor
private final class FakeAccountRepository: AccountRepositoryProtocol {
    var displays: [AccountDisplay] = []
    var groups: [ActualAccountGroup] = []
    var createdNames: [String] = []
    var deletedIDs: [String] = []
    var loadError: Error?
    var createError: Error?
    var writeCalls: [String] = []
    private var parked: (entered: TestLatch, release: TestLatch)?

    /// The next write records itself, signals `entered`, and waits for `release`.
    func parkNextWrite() -> (entered: TestLatch, release: TestLatch) {
        let gate = (entered: TestLatch(), release: TestLatch())
        parked = gate
        return gate
    }

    private func record(_ call: String) async {
        writeCalls.append(call)
        guard let gate = parked else { return }
        parked = nil
        gate.entered.trip()
        await gate.release.wait()
    }

    private var parkedLoad: (entered: TestLatch, release: TestLatch, error: Error?)?

    /// The next refresh signals `entered`, waits for `release`, then throws `error`.
    func parkNextLoad(failingWith error: Error? = nil) -> (entered: TestLatch, release: TestLatch) {
        let gate = (entered: TestLatch(), release: TestLatch())
        parkedLoad = (gate.entered, gate.release, error)
        return gate
    }

    func accountDisplays(budgetID: String) -> [AccountDisplay] { displays }
    func accountGroups(budgetID: String) -> [ActualAccountGroup] { groups }
    func refreshAccountsWithBalances(budgetID: String) async throws {
        if let gate = parkedLoad {
            parkedLoad = nil
            gate.entered.trip()
            await gate.release.wait()
            if let error = gate.error { throw error }
            return
        }
        if let loadError { throw loadError }
    }
    func accountReconciliationSnapshot(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationSnapshot {
        AccountReconciliationSnapshot(
            accountID: accountID,
            accountName: "Account",
            workingBalance: 0,
            clearedBalance: 0,
            lastSyncedBalance: nil,
            lastReconciledMilliseconds: nil,
            capability: .unavailable(.missingLastReconciledColumn)
        )
    }

    func createReconciliationAdjustmentAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult {
        reconciliationResult(accountID: accountID)
    }

    func finishReconciliationAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult {
        reconciliationResult(accountID: accountID)
    }

    func exitReconciliationAndRefresh(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationMutationResult {
        reconciliationResult(accountID: accountID)
    }

    func unlockReconciledTransactionAndRefresh(
        budgetID: String,
        accountID: String,
        transactionID: String
    ) async throws -> AccountReconciliationMutationResult {
        reconciliationResult(accountID: accountID)
    }

    private func reconciliationResult(accountID: String) -> AccountReconciliationMutationResult {
        AccountReconciliationMutationResult(
            snapshot: AccountReconciliationSnapshot(
                accountID: accountID,
                accountName: "Checking",
                workingBalance: 0,
                clearedBalance: 0,
                lastSyncedBalance: nil,
                lastReconciledMilliseconds: nil,
                capability: .available
            ),
            changed: ChangedResources(accounts: [], months: [], transactions: [])
        )
    }
    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {
        await record("createAccount")
    }
    func createAccountGroupAndRefresh(budgetID: String, name: String) async throws {
        await record("createGroup")
        if let createError {
            throw createError
        }
        createdNames.append(name)
    }
    func renameAccountGroupAndRefresh(budgetID: String, groupID: String, name: String) async throws {
        await record("renameGroup")
    }
    func deleteAccountGroupAndRefresh(budgetID: String, groupID: String) async throws {
        await record("deleteGroup")
        deletedIDs.append(groupID)
    }
    func moveAccountToGroupAndRefresh(
        budgetID: String,
        accountID: String,
        groupID: String?
    ) async throws {
        await record("moveAccount")
    }
    func moveAccountGroupAndRefresh(
        budgetID: String,
        groupID: String,
        beforeGroupID: String?
    ) async throws {
        await record("moveGroup")
    }
}
