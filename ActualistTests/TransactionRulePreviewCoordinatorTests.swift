import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionRulePreviewCoordinatorTests {
    @Test func newerRequestWinsOverDelayedOlderRequest() async {
        let oldRequest = Self.request(payeeName: "Old Payee")
        let newRequest = Self.request(payeeName: "New Payee")
        let repository = RecordingTransactionRepository(
            rulePreviewsByPayeeName: [
                "Old Payee": TransactionRulePreview(categoryID: "old", notes: nil),
                "New Payee": TransactionRulePreview(categoryID: "new", notes: nil)
            ],
            pausedRulePreviewPayeeNames: ["Old Payee"]
        )
        let coordinator = TransactionRulePreviewCoordinator()
        var currentRequest = oldRequest

        let oldTask = Task {
            await coordinator.preview(
                request: oldRequest,
                repository: repository,
                currentRequest: { currentRequest }
            )
        }
        while await !repository.isRulePreviewPaused(payeeName: "Old Payee") {
            await Task.yield()
        }

        currentRequest = newRequest
        let newOutcome = await coordinator.preview(
            request: newRequest,
            repository: repository,
            currentRequest: { currentRequest }
        )
        await repository.resumeRulePreview(payeeName: "Old Payee")

        #expect(newOutcome == .applied(TransactionRulePreview(categoryID: "new", notes: nil)))
        #expect(await oldTask.value == TransactionRulePreviewOutcome.stale)
        #expect(!coordinator.isRunning)
    }

    @Test func changedFullDraftMakesDelayedResultStale() async {
        let original = Self.request(payeeName: "Delayed", amount: -1_000)
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(categoryID: "old", notes: "old"),
            pausedRulePreviewPayeeNames: ["Delayed"]
        )
        let coordinator = TransactionRulePreviewCoordinator()
        var currentRequest = original

        let task = Task {
            await coordinator.preview(
                request: original,
                repository: repository,
                currentRequest: { currentRequest }
            )
        }
        while await !repository.isRulePreviewPaused(payeeName: "Delayed") {
            await Task.yield()
        }

        currentRequest = Self.request(payeeName: "Delayed", amount: -2_000)
        await repository.resumeRulePreview(payeeName: "Delayed")

        #expect(await task.value == TransactionRulePreviewOutcome.stale)
    }

    @Test func cancellationSuppressesDelayedResult() async {
        let request = Self.request(payeeName: "Delayed")
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(categoryID: "old", notes: nil),
            pausedRulePreviewPayeeNames: ["Delayed"]
        )
        let coordinator = TransactionRulePreviewCoordinator()

        let task = Task {
            await coordinator.preview(
                request: request,
                repository: repository,
                currentRequest: { request }
            )
        }
        while await !repository.isRulePreviewPaused(payeeName: "Delayed") {
            await Task.yield()
        }

        coordinator.cancel()
        await repository.resumeRulePreview(payeeName: "Delayed")

        #expect(await task.value == TransactionRulePreviewOutcome.stale)
        #expect(!coordinator.isRunning)
    }

    @Test func callerTaskCancellationSuppressesDelayedResult() async {
        let request = Self.request(payeeName: "Delayed")
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(categoryID: "old", notes: nil),
            pausedRulePreviewPayeeNames: ["Delayed"]
        )
        let coordinator = TransactionRulePreviewCoordinator()

        let task = Task {
            await coordinator.preview(
                request: request,
                repository: repository,
                currentRequest: { request }
            )
        }
        while await !repository.isRulePreviewPaused(payeeName: "Delayed") {
            await Task.yield()
        }

        task.cancel()
        await repository.resumeRulePreview(payeeName: "Delayed")

        #expect(await task.value == .stale)
        #expect(!coordinator.isRunning)
    }

    @Test func unsupportedPreviewRemainsSilentOutcome() async {
        let request = Self.request(payeeName: "Unsupported")
        let repository = RecordingTransactionRepository(previewError: LocalFirstError.unsupportedWrite)
        let coordinator = TransactionRulePreviewCoordinator()

        let outcome = await coordinator.preview(
            request: request,
            repository: repository,
            currentRequest: { request }
        )

        #expect(outcome == .unsupported)
        #expect(!coordinator.isRunning)
    }

    private static func request(
        payeeName: String,
        amount: Int = -1_000
    ) -> TransactionRulePreviewRequest {
        TransactionRulePreviewRequest(
            budgetID: "budget",
            draft: TransactionDraft(
                accountID: "checking",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                amountMinorUnits: amount,
                payeeID: nil,
                payeeName: payeeName,
                categoryID: nil,
                notes: nil,
                cleared: false,
                isTransfer: false
            ),
            categorySelection: .single(.init(id: nil, name: nil))
        )
    }
}
