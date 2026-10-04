import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionScheduleConversionCoordinatorTests {
    @Test func reviewCapturesSessionBeforeAwaitAndLateResultIsDiscardedAfterCancel() async throws {
        let repository = FakeConversionRepository()
        let coordinator = TransactionScheduleConversionCoordinator()
        let transaction = ActualTransaction(
            id: "future",
            account: "checking",
            date: "2026-10-01",
            amount: -1200,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: "groceries",
            notes: nil,
            cleared: nil
        )
        let review = ScheduleConversionReview(
            context: repository.context,
            sourceTransactionID: "future",
            asOfDayID: "2026-09-28",
            identity: ScheduleConversionIdentity(scheduleID: "schedule", ruleID: "rule", nextDateID: "next"),
            family: [ScheduleConversionTransactionFact(
                transaction: transaction,
                rawPayeeID: nil,
                transferID: nil,
                isTransferPayee: false
            )]
        )
        repository.reviewResult = review
        repository.reviewEntered = TestLatch()
        repository.releaseReview = TestLatch()
        repository.ignoreReviewCancellation = true

        coordinator.beginReview(
            budgetID: "budget",
            expectedGeneration: repository.context.generation,
            entryPoint: try Self.entryPoint(review: review),
            currency: .usd,
            isPrivacyModeEnabled: false,
            repository: repository
        )
        await repository.reviewEntered?.wait()
        coordinator.beginReview(
            budgetID: "budget",
            expectedGeneration: repository.context.generation,
            entryPoint: try Self.entryPoint(review: review),
            currency: .usd,
            isPrivacyModeEnabled: false,
            repository: repository
        )
        #expect(coordinator.state == .loading)
        #expect(repository.reviewRequests == ["future"])
        let canceled = coordinator.cancel()
        #expect(coordinator.state == .idle)
        repository.releaseReview?.trip()
        await canceled?.value

        #expect(coordinator.state == .idle)
    }

    @Test func confirmsOnlyTheReviewedCurrentSessionAndRetainsDurableReceipt() async throws {
        let repository = FakeConversionRepository()
        let coordinator = TransactionScheduleConversionCoordinator()
        let transaction = ActualTransaction(
            id: "future", account: "checking", date: "2026-10-01", amount: -1200,
            payee: nil, payeeName: nil, importedPayee: nil, category: "groceries",
            notes: nil, cleared: nil
        )
        let review = ScheduleConversionReview(
            context: repository.context,
            sourceTransactionID: "future",
            asOfDayID: "2026-09-28",
            identity: ScheduleConversionIdentity(scheduleID: "schedule", ruleID: "rule", nextDateID: "next"),
            family: [ScheduleConversionTransactionFact(
                transaction: transaction, rawPayeeID: nil, transferID: nil, isTransferPayee: false
            )]
        )
        repository.reviewResult = review
        coordinator.beginReview(
            budgetID: "budget", expectedGeneration: repository.context.generation,
            entryPoint: try Self.entryPoint(review: review),
            currency: .usd,
            isPrivacyModeEnabled: false, repository: repository
        )
        await ObservedTestState { if case .review = coordinator.state { true } else { false } }.wait()

        coordinator.confirm(repository: repository)
        await ObservedTestState { if case .committed = coordinator.state { true } else { false } }.wait()

        #expect(repository.convertedReviews == [review])
        if case .committed(let receipt) = coordinator.state {
            #expect(receipt.refreshPending)
            #expect(receipt.scheduleID == "schedule")
        } else {
            Issue.record("Expected durable conversion receipt")
        }
    }

    @Test func replacingACompletedReviewConvertsOnlyTheNewestSelectedRow() async throws {
        let repository = FakeConversionRepository()
        let coordinator = TransactionScheduleConversionCoordinator()
        repository.reviewResult = Self.review(transactionID: "first", context: repository.context)
        coordinator.beginReview(
            budgetID: "budget", expectedGeneration: repository.context.generation,
            entryPoint: try Self.entryPoint(review: try #require(repository.reviewResult)), currency: .usd,
            isPrivacyModeEnabled: false, repository: repository
        )
        await ObservedTestState {
            if case .review(let content) = coordinator.state {
                content.review.sourceTransactionID == "first"
            } else { false }
        }.wait()

        repository.reviewResult = Self.review(transactionID: "second", context: repository.context)
        let secondEntryPoint = try Self.entryPoint(review: try #require(repository.reviewResult))
        coordinator.beginReview(
            budgetID: "budget", expectedGeneration: repository.context.generation,
            entryPoint: secondEntryPoint, currency: .usd,
            isPrivacyModeEnabled: false, repository: repository
        )
        await ObservedTestState {
            if case .review(let content) = coordinator.state {
                content.review.sourceTransactionID == "second"
            } else { false }
        }.wait()

        coordinator.confirm(repository: repository)
        await ObservedTestState { if case .committed = coordinator.state { true } else { false } }.wait()
        #expect(repository.convertedReviews.map(\.sourceTransactionID) == ["second"])
    }

    @Test func submittingCannotBeDismissedAndRetainsThePostcommitReceipt() async throws {
        let repository = FakeConversionRepository()
        let coordinator = TransactionScheduleConversionCoordinator()
        repository.reviewResult = Self.review(transactionID: "future", context: repository.context)
        coordinator.beginReview(
            budgetID: "budget", expectedGeneration: repository.context.generation,
            entryPoint: try Self.entryPoint(review: try #require(repository.reviewResult)), currency: .usd,
            isPrivacyModeEnabled: false, repository: repository
        )
        await ObservedTestState { if case .review = coordinator.state { true } else { false } }.wait()
        repository.convertEntered = TestLatch()
        repository.releaseConvert = TestLatch()
        let committedContext = repository.context
        var outcome: TransactionScheduleConversionOutcome?

        coordinator.confirm(repository: repository) { outcome = $0 }
        await repository.convertEntered?.wait()
        #expect(coordinator.cancel() == nil)
        #expect(coordinator.state.isSubmitting)
        repository.context = ScheduleConversionSessionContext(budgetID: "replacement", generation: 8)
        repository.releaseConvert?.trip()
        await ObservedTestState { if case .committed = coordinator.state { true } else { false } }.wait()

        if case .committed(let receipt) = coordinator.state {
            #expect(receipt.scheduleID == "schedule-future")
        } else {
            Issue.record("Expected the durable receipt after commit")
        }
        #expect(outcome?.context == committedContext)
        #expect(outcome?.context != repository.context)
    }

    @Test func resolvedNamesArePresentedAndOutcomeRetainsItsOriginSession() async throws {
        let repository = FakeConversionRepository()
        let coordinator = TransactionScheduleConversionCoordinator()
        let review = Self.review(transactionID: "future", context: repository.context)
        repository.reviewResult = review
        let entryPoint = try Self.entryPoint(
            review: review,
            names: TransactionScheduleConversionResolvedNames(
                account: "Everyday Checking",
                payee: "Fresh Market",
                category: "Groceries"
            )
        )
        coordinator.beginReview(
            budgetID: "budget",
            expectedGeneration: repository.context.generation,
            entryPoint: entryPoint,
            currency: .usd,
            isPrivacyModeEnabled: false,
            repository: repository
        )
        await ObservedTestState { if case .review = coordinator.state { true } else { false } }.wait()
        if case .review(let content) = coordinator.state {
            #expect(content.accountText == "Everyday Checking")
            #expect(content.payeeText == "Fresh Market")
            #expect(content.categoryText == "Groceries")
        } else {
            Issue.record("Expected resolved review content")
        }

        var outcome: TransactionScheduleConversionOutcome?
        let completed = TestLatch()
        coordinator.confirm(repository: repository) {
            outcome = $0
            completed.trip()
        }
        _ = await completed.wait(timeout: .seconds(10))
        _ = try #require(outcome, "Conversion completion callback did not arrive before the deadline")
        #expect(outcome?.context == repository.context)
        #expect(outcome?.receipt.scheduleID == review.identity.scheduleID)
        #expect(outcome?.belongsToSession(budgetID: "budget", generation: 7) == true)
        #expect(outcome?.belongsToSession(budgetID: "replacement", generation: 7) == false)
        #expect(outcome?.belongsToSession(budgetID: "budget", generation: 8) == false)
    }

    @Test func staleFeedSourceCannotSupplyNamesForAChangedReview() async throws {
        let repository = FakeConversionRepository()
        let coordinator = TransactionScheduleConversionCoordinator()
        let staleReview = Self.review(transactionID: "future", context: repository.context)
        var changed = Self.review(transactionID: "future", context: repository.context)
        let changedSource = ActualTransaction(
            id: "future", account: "savings", date: "2026-10-01", amount: -1200,
            payee: nil, payeeName: nil, importedPayee: nil, category: "groceries",
            notes: nil, cleared: nil
        )
        changed = ScheduleConversionReview(
            context: changed.context,
            sourceTransactionID: changed.sourceTransactionID,
            asOfDayID: changed.asOfDayID,
            identity: changed.identity,
            family: [ScheduleConversionTransactionFact(
                transaction: changedSource, rawPayeeID: nil, transferID: nil, isTransferPayee: false
            )]
        )
        repository.reviewResult = changed

        coordinator.beginReview(
            budgetID: "budget",
            expectedGeneration: repository.context.generation,
            entryPoint: try Self.entryPoint(review: staleReview),
            currency: .usd,
            isPrivacyModeEnabled: false,
            repository: repository
        )
        await ObservedTestState { if case .failed = coordinator.state { true } else { false } }.wait()
        if case .failed(let message) = coordinator.state {
            #expect(message.contains("changed"))
        }
    }

    @Test func unsupportedSchemaConversionFailureSurfacesTesterVoicedNotice() async throws {
        let repository = FakeConversionRepository()
        repository.convertError = ScheduleConversionError.unsupportedSchema
        let coordinator = TransactionScheduleConversionCoordinator()
        repository.reviewResult = Self.review(transactionID: "future", context: repository.context)
        coordinator.beginReview(
            budgetID: "budget", expectedGeneration: repository.context.generation,
            entryPoint: try Self.entryPoint(review: try #require(repository.reviewResult)),
            currency: .usd,
            isPrivacyModeEnabled: false, repository: repository
        )
        await ObservedTestState { if case .review = coordinator.state { true } else { false } }.wait()

        coordinator.confirm(repository: repository)
        await ObservedTestState { if case .failed = coordinator.state { true } else { false } }.wait()

        guard case .failed(let message) = coordinator.state else {
            Issue.record("Expected the conversion failure to present a notice")
            return
        }
        #expect(message == ScheduleMutationUserNotice.unsupportedBudgetSchedules)
        #expect(!message.contains("missing column"))
    }

    private static func entryPoint(
        review: ScheduleConversionReview,
        names: TransactionScheduleConversionResolvedNames = TransactionScheduleConversionResolvedNames(
            account: "Checking", payee: "No payee", category: "Groceries"
        )
    ) throws -> TransactionScheduleConversionEntryPoint {
        TransactionScheduleConversionEntryPoint(
            transactionID: review.sourceTransactionID,
            asOfDayID: review.asOfDayID,
            source: try #require(review.source),
            names: names
        )
    }

    private static func review(
        transactionID: String,
        context: ScheduleConversionSessionContext
    ) -> ScheduleConversionReview {
        ScheduleConversionReview(
            context: context,
            sourceTransactionID: transactionID,
            asOfDayID: "2026-09-28",
            identity: ScheduleConversionIdentity(
                scheduleID: "schedule-\(transactionID)",
                ruleID: "rule-\(transactionID)",
                nextDateID: "next-\(transactionID)"
            ),
            family: [ScheduleConversionTransactionFact(
                transaction: ActualTransaction(
                    id: transactionID, account: "checking", date: "2026-10-01", amount: -1200,
                    payee: nil, payeeName: nil, importedPayee: nil, category: "groceries",
                    notes: nil, cleared: nil
                ),
                rawPayeeID: nil,
                transferID: nil,
                isTransferPayee: false
            )]
        )
    }
}

@MainActor
private final class FakeConversionRepository: TransactionScheduleConversionRepositoryProtocol {
    var context = ScheduleConversionSessionContext(budgetID: "budget", generation: 7)
    var reviewResult: ScheduleConversionReview?
    var reviewEntered: TestLatch?
    var releaseReview: TestLatch?
    var ignoreReviewCancellation = false
    var convertedReviews: [ScheduleConversionReview] = []
    var reviewRequests: [String] = []
    var convertEntered: TestLatch?
    var releaseConvert: TestLatch?
    var convertError: Error?

    func scheduleConversionSessionContext(budgetID: String) throws -> ScheduleConversionSessionContext {
        context
    }

    func scheduleConversionReview(
        budgetID: String,
        transactionID: String,
        asOfDayID: String
    ) async throws -> ScheduleConversionReview {
        reviewRequests.append(transactionID)
        reviewEntered?.trip()
        if ignoreReviewCancellation {
            await releaseReview?.wait()
        } else {
            try Task.checkCancellation()
        }
        guard let reviewResult else { throw CancellationError() }
        return reviewResult
    }

    func convertFutureTransaction(review: ScheduleConversionReview) async throws -> ScheduleConversionReceipt {
        if let convertError { throw convertError }
        convertedReviews.append(review)
        convertEntered?.trip()
        await releaseConvert?.wait()
        return ScheduleConversionReceipt(
            scheduleID: review.identity.scheduleID,
            sourceTransactionIDs: review.sourceTransactionIDs,
            appliedMessageCount: 4,
            refreshPending: true
        )
    }
}
