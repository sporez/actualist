import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountRunningBalanceViewModelTests {
    private let account = AccountTransactionsViewModelTests.account

    @Test func enablingWritesTheAbsoluteValueForThisAccount() async {
        let repository = AccountTransactionsRecordingRepository()
        let model = AccountTransactionsViewModel(scope: .account(account))

        await model.setRunningBalance(true, budgetID: "budget", repository: repository)

        #expect(repository.runningBalanceWrites == [
            .init(budgetID: "budget", accountID: "checking", enabled: true)
        ])
        #expect(!model.isUpdatingRunningBalance)
        #expect(model.errorMessage == nil)
    }

    @Test func failureSurfacesTheErrorAndReenablesTheMenu() async {
        let repository = AccountTransactionsRecordingRepository()
        repository.runningBalanceError = FeedTestError("no preferences")
        let model = AccountTransactionsViewModel(scope: .account(account))

        await model.setRunningBalance(true, budgetID: "budget", repository: repository)

        #expect(model.errorMessage == "no preferences")
        #expect(!model.isUpdatingRunningBalance)
    }

    @Test func secondRequestWhileOneIsInFlightIsIgnored() async {
        let repository = AccountTransactionsRecordingRepository()
        repository.suspendsRunningBalanceWrites = true
        let model = AccountTransactionsViewModel(scope: .account(account))

        let first = Task { await model.setRunningBalance(true, budgetID: "budget", repository: repository) }
        await repository.runningBalanceWriteStarted.wait()
        #expect(model.isUpdatingRunningBalance)
        await model.setRunningBalance(false, budgetID: "budget", repository: repository)
        repository.runningBalanceRelease.trip()
        await first.value

        #expect(repository.runningBalanceWrites.count == 1)
        #expect(!model.isUpdatingRunningBalance)
    }

    @Test func resultAfterTheBudgetChangedDoesNotTouchTheNewScreen() async {
        let repository = AccountTransactionsRecordingRepository()
        repository.suspendsRunningBalanceWrites = true
        repository.runningBalanceError = FeedTestError("late failure")
        let model = AccountTransactionsViewModel(scope: .account(account))

        let stale = Task { await model.setRunningBalance(true, budgetID: "old", repository: repository) }
        await repository.runningBalanceWriteStarted.wait()
        await model.budgetDidChange(to: "new", repository: AccountTransactionsRecordingRepository())
        #expect(!model.isUpdatingRunningBalance)
        repository.runningBalanceRelease.trip()
        await stale.value

        #expect(model.errorMessage == nil)
        #expect(!model.isUpdatingRunningBalance)
    }

    @Test func spendingScopeHasNoAccountToWrite() async {
        let repository = AccountTransactionsRecordingRepository()
        let model = AccountTransactionsViewModel(scope: .spending)

        await model.setRunningBalance(true, budgetID: "budget", repository: repository)

        #expect(repository.runningBalanceWrites.isEmpty)
    }
}
