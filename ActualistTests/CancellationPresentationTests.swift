import Foundation
import Testing
@testable import Actualist

@MainActor
struct CancellationPresentationTests {
    @Test(arguments: CancellationTestCase.allCases)
    func cancellationHasNoUserFacingMessage(_ kind: CancellationTestCase) {
        #expect(kind.error.isCancellation)
        #expect(kind.error.userFacingMessage == nil)
        #expect(!LocalFirstActualStore.isFailoverEligible(kind.error))
    }

    @Test func genuineErrorsRemainVisibleEvenInsideACancelledTask() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            for error in [ActualAPIError.transport(.cannotConnectToHost), .transport(.timedOut),
                          .transport(.notConnectedToInternet), .httpStatus(401), .decoding] {
                #expect(!error.isCancellation)
                #expect(error.userFacingMessage == error.localizedDescription)
            }
            let writeError = LocalFirstError.invalidLocalWrite("The write failed.")
            #expect(writeError.userFacingMessage == writeError.localizedDescription)
            let unrelated = NSError(domain: "unrelated", code: NSURLErrorCancelled)
            #expect(!unrelated.isCancellation)
        }
        await task.value
    }

    @Test(arguments: CancellationTestCase.allCases)
    func budgetCancellationKeepsCachedMonthAndAllowsRetry(_ kind: CancellationTestCase) async {
        let cached = BudgetViewportFixtures.loaded("2026-07")
        let repository = BudgetViewportTestRepository()
        let model = BudgetViewModel(initialMonth: cached, initialBudgetID: "budget")
        await repository.setCurrentReadError(kind.error)
        await model.load(budgetID: "budget", repository: repository)
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
        #expect(model.budgetMonth == cached.month)
        await repository.setError(kind.error, for: "2026-08")
        await model.selectMonth("2026-08", budgetID: "budget", repository: repository)
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
        #expect(model.selectedMonth == "2026-07")
        await repository.setError(nil, for: "2026-08")
        await repository.set(BudgetViewportFixtures.loaded("2026-08"))
        await model.selectMonth("2026-08", budgetID: "budget", repository: repository)
        #expect(model.selectedMonth == "2026-08")
    }

    @Test(arguments: [false, true])
    func olderBudgetReadCannotReplaceNewerSelection(fails: Bool) async {
        let repository = BudgetViewportTestRepository()
        let july = BudgetViewportFixtures.loaded("2026-07")
        await repository.set(july)
        await repository.set(BudgetViewportFixtures.loaded("2026-08"))
        let model = BudgetViewModel(initialMonth: july, initialBudgetID: "budget")
        await repository.block("2026-07")
        let old = Task { await model.load(budgetID: "budget", repository: repository) }
        await repository.waitUntilReadBlocked("2026-07")
        await model.selectMonth("2026-08", budgetID: "budget", repository: repository)
        if fails { await repository.setError(ActualAPIError.transport(.cannotConnectToHost), for: "2026-07") }
        await repository.release("2026-07")
        await old.value
        #expect(model.selectedMonth == "2026-08")
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    @Test func cancelledBudgetTaskCannotApplyCancellationInsensitiveRead() async {
        let repository = BudgetViewportTestRepository()
        await repository.set(BudgetViewportFixtures.loaded("2026-08"))
        await repository.block("2026-08")
        let model = BudgetViewModel(initialMonth: BudgetViewportFixtures.loaded("2026-07"), initialBudgetID: "budget")
        let task = Task { await model.selectMonth("2026-08", budgetID: "budget", repository: repository) }
        await repository.waitUntilReadBlocked("2026-08")
        task.cancel()
        await repository.release("2026-08")
        await task.value
        #expect(model.selectedMonth == "2026-07")
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    @Test(arguments: CancellationTestCase.allCases)
    func viewportCancellationDoesNotBecomeAPartialMonthFailure(_ kind: CancellationTestCase) async {
        let repository = BudgetViewportTestRepository()
        let july = BudgetViewportFixtures.loaded("2026-07")
        await repository.set(july)
        let model = BudgetViewportModel(repository: repository)
        await model.load(budgetID: "budget", anchorMonth: "2026-07")
        model.setResolvedMonthCount(2)
        await repository.setError(kind.error, for: "2026-08")
        #expect(await model.refreshVisibleMonths() == false)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
        #expect(model.monthErrors.isEmpty)
        #expect(model.snapshot(for: "2026-07") == july)
    }

    @Test(arguments: CancellationTestCase.allCases)
    func budgetWriteCancellationEndsSubmissionWithoutAnError(_ kind: CancellationTestCase) async throws {
        let loaded = BudgetViewportFixtures.loaded("2026-07")
        let category = try #require(loaded.month.categoryGroups.first?.categories.first)
        let repository = RecordingBudgetRepository(loadedMonth: loaded, assignError: kind.error,
                                                   moveError: kind.error, templateError: kind.error)
        let model = BudgetViewModel(initialMonth: loaded, initialBudgetID: "budget")
        model.beginAssignmentEditing(for: category)
        model.appendAssignmentDigit(5)
        #expect(await model.submitAssignment(budgetID: "budget", repository: repository) == false)
        #expect(model.activeAssignmentErrorMessage == nil)
        #expect(model.assignmentDraft?.submissionState == .draft)
        #expect(await model.applyCategoryTemplate(budgetID: "budget", repository: repository) == false)
        #expect(model.activeAssignmentErrorMessage == nil)
        #expect(!model.isSubmittingAssignment)
        #expect(await model.applyMonthTemplate(.fillEmpty, budgetID: "budget", repository: repository) == false)
        #expect(model.errorMessage == nil)
        #expect(model.monthTemplateSubmissionState == .draft)
        model.beginMoveMoney(for: category.id)
        model.selectMoveMoneyDestination(.toBudget)
        model.appendMoveMoneyDigit(5)
        #expect(await model.submitMoveMoney(budgetID: "budget", repository: repository) == false)
        #expect(model.activeMoveMoneyErrorMessage == nil)
        #expect(!model.isSubmittingMoveMoney)
        #expect(model.budgetMonth == loaded.month)
    }

    @Test(arguments: CancellationTestCase.allCases)
    func transactionCancellationDoesNotReportASuccessfulSave(_ kind: CancellationTestCase) async {
        let model = TransactionEditorViewModel()
        model.selectedAccountID = "checking"
        model.payeeName = "Shop"
        model.amountDigits = "500"
        #expect(await model.submit(budgetID: "budget", repository: RecordingTransactionRepository(createError: kind.error)) == false)
        #expect(model.errorMessage == nil)
        #expect(model.submissionState == .draft)
        #expect(model.canSave)
        #expect(await model.submit(budgetID: "budget", repository: RecordingTransactionRepository()))
        #expect(model.submissionState == .clean)
    }
}
