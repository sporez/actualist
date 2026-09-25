import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountTransactionsViewModelReadStateTests {
    @Test func mergedFeedPagesShareOneIdentityAndMetadataPolicy() {
        let duplicate = AccountTransactionsViewModelTests.transaction(id: "duplicate")
        let current = LoadedAccountTransactions(
            transactions: [duplicate], balance: 10,
            categoryNames: ["food": "Food"], payeeNames: ["market": "Market"],
            transferPayeeIDs: ["transfer"], offBudgetAccountIDs: ["off-budget"],
            reachedEnd: false, nextOffset: 1
        )
        let older = LoadedAccountTransactions(
            transactions: [duplicate, AccountTransactionsViewModelTests.transaction(id: "older")],
            balance: 20, categoryNames: [:], payeeNames: [:], transferPayeeIDs: [],
            offBudgetAccountIDs: [], reachedEnd: true, nextOffset: 2
        )

        let merged = current.appendingPage(older)

        #expect(merged.transactions.map(\.rowID) == ["duplicate", "older"])
        #expect(merged.balance == 20)
        #expect(merged.categoryNames == current.categoryNames)
        #expect(merged.payeeNames == current.payeeNames)
        #expect(merged.transferPayeeIDs == current.transferPayeeIDs)
        #expect(merged.offBudgetAccountIDs.isEmpty)
        #expect(merged.nextOffset == 2)
        #expect(merged.reachedEnd)
    }

    @Test func sameQueryRefreshReloadsTheAlreadyLoadedSearchWindow() async {
        let first = AccountTransactionsViewModelTests.loaded(
            (0..<50).map { AccountTransactionsViewModelTests.transaction(id: "first-\($0)") },
            reachedEnd: false,
            nextOffset: 50
        )
        let second = AccountTransactionsViewModelTests.loaded(
            (0..<50).map { AccountTransactionsViewModelTests.transaction(id: "second-\($0)") },
            reachedEnd: false,
            nextOffset: 100
        )
        let refreshedWindow = AccountTransactionsViewModelTests.loaded(
            (0..<100).map { AccountTransactionsViewModelTests.transaction(id: "refresh-\($0)") },
            reachedEnd: false,
            nextOffset: 100
        )
        let repository = AccountTransactionsRecordingRepository(
            searchPages: ["market|all|0": first, "market|all|50": second],
            searchPagesByLimit: ["market|all|0|100": refreshedWindow]
        )
        let model = AccountTransactionsViewModel(scope: .spending, searchDelay: .zero)
        model.searchText = "market"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        await repository.waitForSearch("market|all|0")
        await ObservedTestState { !model.isSearching }.wait()
        await model.loadOlder(budgetID: "budget", repository: repository)

        await model.refresh(budgetID: "budget", repository: repository, sync: {}, onChanged: {})

        let display = model.displayState(budgetID: "budget", repository: repository,
                                         pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(repository.searchRequests == ["market|all|0", "market|all|50", "market|all|0"])
        #expect(repository.searchLimits == [50, 50, 100])
        #expect(display.transactionCount == 100)
        #expect(display.groups.flatMap(\.rows).first?.id == "refresh-0")
    }

    @Test func failedSameQueryRefreshKeepsCachedWindowAndReportsNonblockingError() async {
        let first = AccountTransactionsViewModelTests.loaded(
            (0..<50).map { AccountTransactionsViewModelTests.transaction(id: "first-\($0)") },
            reachedEnd: false,
            nextOffset: 50
        )
        let second = AccountTransactionsViewModelTests.loaded(
            (0..<50).map { AccountTransactionsViewModelTests.transaction(id: "second-\($0)") },
            reachedEnd: false,
            nextOffset: 100
        )
        let repository = AccountTransactionsRecordingRepository(
            searchPages: ["market|all|0": first, "market|all|50": second],
            searchErrorsByLimit: ["market|all|0|100"]
        )
        let model = AccountTransactionsViewModel(scope: .spending, searchDelay: .zero)
        model.searchText = "market"
        model.scheduleSearch(budgetID: "budget", repository: repository)
        await repository.waitForSearch("market|all|0")
        await ObservedTestState { !model.isSearching }.wait()
        await model.loadOlder(budgetID: "budget", repository: repository)

        await model.refresh(budgetID: "budget", repository: repository, sync: {}, onChanged: {})

        let display = model.displayState(budgetID: "budget", repository: repository,
                                         pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(display.transactionCount == 100)
        #expect(display.groups.flatMap(\.rows).first?.id == "first-0")
        #expect(model.searchErrorMessage?.contains("Could not refresh all search results") == true)
        #expect(!model.isSearchLoading(budgetID: "budget"))
    }

    @Test func cancelledSearchDiscardsLateCompletionAndResumesAfterEditorReturn() async {
        let repository = AccountTransactionsRecordingRepository(suspendsSearches: true)
        let model = AccountTransactionsViewModel(scope: .spending, searchDelay: .zero)
        model.searchTextDidChange("market", budgetID: "budget", repository: repository)
        await repository.waitForSearch("market|all|0")

        model.feedDidDisappear(editorIsPresented: true)
        #expect(!model.isSearchLoading(budgetID: "budget"))
        await repository.finishSearch("market", with: AccountTransactionsViewModelTests.loaded([
            AccountTransactionsViewModelTests.transaction(id: "cancelled-result")
        ]))
        await Task.yield()

        let cancelledDisplay = model.displayState(budgetID: "budget", repository: repository,
                                                 pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(cancelledDisplay.transactionCount == 0)
        model.editorPresentationChanged(editorDismissed: true, budgetID: "budget", repository: repository)
        await repository.waitForSearch("market|all|0", occurrence: 2)
        await repository.finishSearch("market", with: AccountTransactionsViewModelTests.loaded([
            AccountTransactionsViewModelTests.transaction(id: "resumed-result")
        ]))
        await ObservedTestState { !model.isSearching }.wait()

        let resumed = model.displayState(budgetID: "budget", repository: repository,
                                         pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(resumed.groups.flatMap(\.rows).map(\.id) == ["resumed-result"])
    }

    @Test func staleFilterLoadCompletionCannotReplaceNewFilterState() async {
        let all = AccountTransactionsViewModelTests.loaded([
            AccountTransactionsViewModelTests.transaction(id: "all")
        ])
        let repository = AccountTransactionsRecordingRepository(
            filterSnapshots: [
                .all: all,
                .uncleared: AccountTransactionsViewModelTests.loaded([
                    AccountTransactionsViewModelTests.transaction(id: "uncleared")
                ]),
                .cleared: AccountTransactionsViewModelTests.loaded([
                    AccountTransactionsViewModelTests.transaction(id: "cleared")
                ]),
            ],
            suspendsRefreshFilters: [.uncleared, .cleared]
        )
        let model = AccountTransactionsViewModel(scope: .account(AccountTransactionsViewModelTests.account))
        await model.loadLocal(budgetID: "budget", repository: repository)
        let staleLoad = Task {
            await model.selectFilter(.uncleared, budgetID: "budget", repository: repository)
        }
        await repository.waitForRefresh(.uncleared)
        let currentLoad = Task {
            await model.selectFilter(.cleared, budgetID: "budget", repository: repository)
        }
        await repository.waitForRefresh(.cleared)

        await repository.finishRefresh(.cleared)
        await currentLoad.value
        await repository.finishRefresh(.uncleared)
        await staleLoad.value

        let display = model.displayState(budgetID: "budget", repository: repository,
                                         pendingNewTransactionIDs: [], privacyModeEnabled: false)
        #expect(model.statusFilter == .cleared)
        #expect(display.groups.flatMap(\.rows).map(\.id) == ["cleared"])
    }
}
