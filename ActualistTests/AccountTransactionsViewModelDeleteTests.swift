import Foundation
import Testing
@testable import Actualist

/// Delete workflow of `AccountTransactionsViewModel`: confirmation, failure
/// and success feedback, the local-change callback, and reconciled
/// authorization. Fixtures are shared with `AccountTransactionsViewModelTests`.
@MainActor
struct AccountTransactionsViewModelDeleteTests {
    @Test func confirmedDeletePreservesFailureAndPublishesSuccess() async {
        let transaction = AccountTransactionsViewModelTests.transaction(id: "delete-me", payee: "market")
        let failingRepository = AccountTransactionsRecordingRepository(
            accountSnapshot: AccountTransactionsViewModelTests.loaded([transaction]),
            deleteError: FeedTestError("delete failed")
        )
        let model = AccountTransactionsViewModel(scope: .account(AccountTransactionsViewModelTests.account))

        await model.requestDelete(transaction, budgetID: "budget", repository: failingRepository)
        #expect(model.deletePresentation?.payeeName == "Market")
        #expect(model.deleteIntentFeedback == 1)

        await model.delete(
            transaction,
            budgetID: "budget",
            repository: failingRepository,
            onChanged: {}
        )
        #expect(model.errorMessage == "delete failed")
        #expect(model.deleteSuccessFeedback == 0)
        #expect(model.deletingTransactionID == nil)

        let successfulRepository = AccountTransactionsRecordingRepository(
            accountSnapshot: AccountTransactionsViewModelTests.loaded([transaction])
        )
        await model.delete(
            transaction,
            budgetID: "budget",
            repository: successfulRepository,
            onChanged: {}
        )
        #expect(model.errorMessage == nil)
        #expect(model.deleteSuccessFeedback == 1)
        #expect(successfulRepository.deletedTransactionIDs == ["delete-me"])
    }

    @Test func successfulDeleteReportsOneLocalChangeForEveryScope() async {
        let transaction = AccountTransactionsViewModelTests.transaction(id: "delete-me", payee: "market")
        let scopes: [TransactionFeedScope] = [
            .account(AccountTransactionsViewModelTests.account),
            .spending,
            .category(AccountTransactionsViewModelTests.categoryDetails),
        ]
        for scope in scopes {
            let repository = AccountTransactionsRecordingRepository(
                accountSnapshot: AccountTransactionsViewModelTests.loaded([transaction])
            )
            let model = AccountTransactionsViewModel(scope: scope)
            var changes = 0
            await model.delete(
                transaction,
                budgetID: "budget",
                repository: repository,
                onChanged: { changes += 1 }
            )
            #expect(changes == 1)
        }
    }

    @Test func committedCategoryDeleteIsSuccessWhenItsFollowUpRefreshFails() async {
        let transaction = AccountTransactionsViewModelTests.transaction(id: "delete-me", payee: "market")
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: AccountTransactionsViewModelTests.loaded([transaction]),
            refreshError: FeedTestError("refresh failed")
        )
        let model = AccountTransactionsViewModel(
            scope: .category(AccountTransactionsViewModelTests.categoryDetails)
        )
        await model.requestDelete(transaction, budgetID: "budget", repository: repository)
        #expect(model.deletePresentation != nil)
        var changes = 0

        let deleted = await model.delete(
            transaction,
            budgetID: "budget",
            repository: repository,
            onChanged: { changes += 1 }
        )

        #expect(deleted)
        #expect(changes == 1)
        #expect(model.deletePresentation == nil)
        #expect(model.deleteSuccessFeedback == 1)
        #expect(repository.deletedTransactionIDs == ["delete-me"])
        #expect(model.errorMessage == "refresh failed")
    }

    @Test func failedDeleteDoesNotReportALocalChange() async {
        let transaction = AccountTransactionsViewModelTests.transaction(id: "delete-me", payee: "market")
        for scope in [TransactionFeedScope.account(AccountTransactionsViewModelTests.account), .spending] {
            let repository = AccountTransactionsRecordingRepository(
                accountSnapshot: AccountTransactionsViewModelTests.loaded([transaction]),
                deleteError: FeedTestError("delete failed")
            )
            let model = AccountTransactionsViewModel(scope: scope)
            var changes = 0
            await model.delete(
                transaction,
                budgetID: "budget",
                repository: repository,
                onChanged: { changes += 1 }
            )
            #expect(changes == 0)
        }
    }

    @Test func reconciledDeleteUsesPreparedWarningAndExactAuthorization() async {
        let transaction = AccountTransactionsViewModelTests.transaction(id: "locked", payee: "market")
        let review = ReconciledTransactionMutationReview(
            transactionID: "locked",
            targetReconciledTransactionIDs: ["locked"],
            pairedReconciledTransactionIDs: ["paired"]
        )
        let repository = AccountTransactionsRecordingRepository(
            accountSnapshot: AccountTransactionsViewModelTests.loaded([transaction]),
            reconciliationReview: review
        )
        let model = AccountTransactionsViewModel(scope: .account(AccountTransactionsViewModelTests.account))

        await model.requestDelete(transaction, budgetID: "budget", repository: repository)

        #expect(model.deletePresentation?.confirmationTitle == "Delete Reconciled Transaction?")
        #expect(model.deletePresentation?.message.contains("other side of its transfer") == true)
        let authorization = model.deletePresentation?.reconciliationAuthorization
        await model.delete(
            transaction,
            budgetID: "budget",
            repository: repository,
            reconciliationAuthorization: authorization,
            onChanged: {}
        )

        #expect(repository.deleteAuthorizations == [review.authorization])
        #expect(repository.deletedTransactionIDs == ["locked"])
    }
}
