import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountsViewModelTests {
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
    var managementEnabled = true
    var createdNames: [String] = []
    var deletedIDs: [String] = []
    var createError: Error?

    func accountDisplays(budgetID: String) -> [AccountDisplay] { displays }
    func accountGroups(budgetID: String) -> [ActualAccountGroup] { groups }
    func accountGroupManagementEnabled(budgetID: String) -> Bool { managementEnabled }
    func refreshAccountsWithBalances(budgetID: String) async throws {}
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
    func reconcileAccountAndRefresh(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> AccountReconciliationResult {
        throw LocalFirstError.unsupportedWrite
    }
}
