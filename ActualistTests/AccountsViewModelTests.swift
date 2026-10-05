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
}

@MainActor
private final class FakeAccountRepository: AccountRepositoryProtocol {
    var displays: [AccountDisplay] = []
    var groups: [ActualAccountGroup] = []
    var createdNames: [String] = []
    var deletedIDs: [String] = []
    var loadError: Error?
    var createError: Error?

    func accountDisplays(budgetID: String) -> [AccountDisplay] { displays }
    func accountGroups(budgetID: String) -> [ActualAccountGroup] { groups }
    func refreshAccountsWithBalances(budgetID: String) async throws { if let loadError { throw loadError } }
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
    func createAccountAndRefresh(budgetID: String, name: String, offbudget: Bool) async throws {}
    func createAccountGroupAndRefresh(budgetID: String, name: String) async throws {
        if let createError {
            throw createError
        }
        createdNames.append(name)
    }
    func renameAccountGroupAndRefresh(budgetID: String, groupID: String, name: String) async throws {}
    func deleteAccountGroupAndRefresh(budgetID: String, groupID: String) async throws {
        deletedIDs.append(groupID)
    }
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
}
