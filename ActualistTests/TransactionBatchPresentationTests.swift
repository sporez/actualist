import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionBatchPresentationTests {
    @Test func latePreparationErrorDoesNotDismissNewReview() async throws {
        let repository = DeferredFirstBatchReviewRepository(firstRequestFails: true)
        let presentation = TransactionBatchPresentation()
        let context = makeContext()
        let snapshot = TransactionBatchFeedSnapshot(context: context)

        presentation.enter(context: context)
        presentation.toggle(transaction(id: "first"))
        let obsoleteTask = try #require(presentation.prepare(intent: .delete, feedSnapshot: snapshot, repository: repository))
        guard await repository.waitForFirstRequest() else {
            obsoleteTask.cancel()
            repository.releaseFirstRequest()
            await obsoleteTask.value
            Issue.record("The first review did not reach its bounded gate")
            return
        }

        presentation.cancelSheet()
        presentation.enter(context: context)
        presentation.toggle(transaction(id: "second"))
        guard let currentTask = presentation.prepare(intent: .delete, feedSnapshot: snapshot, repository: repository) else {
            repository.releaseFirstRequest()
            await obsoleteTask.value
            Issue.record("Expected a new review task")
            return
        }
        await currentTask.value
        #expect(presentation.sheetContent == .review)
        guard case .reviewing(let currentReview) = presentation.selection.state else {
            repository.releaseFirstRequest()
            await obsoleteTask.value
            Issue.record("Expected the new request to reach review")
            return
        }

        repository.releaseFirstRequest()
        await obsoleteTask.value

        #expect(presentation.sheetContent == .review)
        #expect(presentation.selection.state == .reviewing(currentReview))
    }

    @Test func latePreparationSuccessDoesNotReplaceNewReview() async throws {
        let repository = DeferredFirstBatchReviewRepository(firstRequestFails: false)
        let presentation = TransactionBatchPresentation()
        let context = makeContext()
        let snapshot = TransactionBatchFeedSnapshot(context: context)

        presentation.enter(context: context)
        presentation.toggle(transaction(id: "first"))
        let obsoleteTask = try #require(presentation.prepare(intent: .delete, feedSnapshot: snapshot, repository: repository))
        guard await repository.waitForFirstRequest() else {
            obsoleteTask.cancel()
            repository.releaseFirstRequest()
            await obsoleteTask.value
            Issue.record("The first review did not reach its bounded gate")
            return
        }

        presentation.cancelSheet()
        presentation.enter(context: context)
        presentation.toggle(transaction(id: "second"))
        guard let currentTask = presentation.prepare(intent: .delete, feedSnapshot: snapshot, repository: repository) else {
            repository.releaseFirstRequest()
            await obsoleteTask.value
            Issue.record("Expected a new review task")
            return
        }
        await currentTask.value
        guard case .reviewing(let currentReview) = presentation.selection.state else {
            repository.releaseFirstRequest()
            await obsoleteTask.value
            Issue.record("Expected the new request to reach review")
            return
        }

        repository.releaseFirstRequest()
        await obsoleteTask.value

        #expect(presentation.sheetContent == .review)
        #expect(presentation.selection.state == .reviewing(currentReview))
    }

    @Test func exactReviewDisplayNamesRowsAndShowsLinkedBeforeAfterEffects() throws {
        let selected = try #require(TransactionSelectionIdentity(
            transactionID: "selected",
            familyRootID: "selected",
            role: .root
        ))
        let selectedBefore = reviewRow(
            id: "selected",
            accountID: "checking",
            amount: -12_345,
            payeeID: "coffee",
            transferID: "paired"
        )
        let pairedBefore = reviewRow(
            id: "paired",
            accountID: "credit",
            amount: 12_345,
            payeeID: "transfer",
            transferID: "selected"
        )
        let review = TransactionBatchReview(
            id: "review",
            context: makeContext(),
            intent: .delete,
            selections: [selected],
            dispositions: [.eligible(TransactionBatchEffectSummary(
                selection: selected,
                affectedTransactionIDs: ["selected", "paired"],
                description: "Delete the selected transaction and its transfer."
            ))],
            rowChanges: [
                TransactionBatchRowChange(before: selectedBefore, after: tombstoned(selectedBefore)),
                TransactionBatchRowChange(before: pairedBefore, after: tombstoned(pairedBefore)),
            ],
            metadata: TransactionBatchReviewMetadata(
                currency: .usd,
                accountNames: ["checking": "Checking", "credit": "Credit Card"],
                payeeNames: ["coffee": "Coffee Shop", "transfer": "Checking"],
                categoryNames: [:]
            ),
            clearTarget: nil,
            reviewFingerprint: "fingerprint",
            effectsDescription: "Two rows will be deleted.",
            authorization: nil,
            canSubmit: true
        )

        let display = TransactionBatchReviewDisplay(review: review, locale: Locale(identifier: "en_US"))
        let row = try #require(display.rows.first)
        let member = try #require(row.member)
        #expect(member.payee == "Coffee Shop")
        #expect(member.context == "Jul 3, 2026 · Checking")
        #expect(member.amount == BudgetCurrency.usd.formatted(-12_345))
        #expect(member.effects == [.init(title: "Status", before: "Present", after: "Deleted")])
        let linked = try #require(row.linkedMembers.first)
        #expect(linked.payee == "Checking")
        #expect(linked.context == "Jul 3, 2026 · Credit Card")
        #expect(linked.relation == "Affected transfer member")
        #expect(linked.effects == [.init(title: "Status", before: "Present", after: "Deleted")])
    }

    @Test func exactReviewDisplayKeepsSkippedAndBlockedRowsRecognizable() throws {
        let skipped = try #require(TransactionSelectionIdentity(
            transactionID: "skipped", familyRootID: "skipped", role: .root
        ))
        let blocked = try #require(TransactionSelectionIdentity(
            transactionID: "blocked", familyRootID: "blocked", role: .root
        ))
        let skippedRow = reviewRow(
            id: "skipped", accountID: "checking", amount: -500,
            payeeID: "coffee", transferID: "pair"
        )
        let blockedRow = reviewRow(
            id: "blocked", accountID: "credit", amount: -900,
            payeeID: "store", transferID: "pair-2"
        )
        let review = TransactionBatchReview(
            id: "review",
            context: makeContext(),
            intent: .clear,
            selections: [skipped, blocked],
            dispositions: [
                .skipped(.init(selection: skipped, explanation: "Reconciled transactions are left unchanged.")),
                .blocked(.init(selection: blocked, explanation: "The transfer pair is incomplete.")),
            ],
            rowChanges: [
                .init(before: skippedRow, after: skippedRow),
                .init(before: blockedRow, after: blockedRow),
            ],
            metadata: .init(
                currency: .usd,
                accountNames: ["checking": "Checking", "credit": "Credit Card"],
                payeeNames: ["coffee": "Coffee Shop", "store": "Corner Store"],
                categoryNames: [:]
            ),
            clearTarget: true,
            reviewFingerprint: "fingerprint",
            effectsDescription: "No rows can change.",
            authorization: nil,
            canSubmit: false
        )

        let display = TransactionBatchReviewDisplay(review: review, locale: Locale(identifier: "en_US"))
        #expect(display.rows.compactMap { $0.member?.payee } == ["Coffee Shop", "Corner Store"])
        #expect(display.rows.map(\.status) == ["Skipped", "Blocked"])
        #expect(display.rows.map(\.explanation) == [
            "Reconciled transactions are left unchanged.",
            "The transfer pair is incomplete.",
        ])
    }

    @Test func missingSelectedSnapshotRemainsVisibleAsUnavailableBlockedRow() throws {
        let missing = try #require(TransactionSelectionIdentity(
            transactionID: "missing", familyRootID: "missing", role: .root
        ))
        let review = TransactionBatchReview(
            id: "review",
            context: makeContext(),
            intent: .delete,
            selections: [missing],
            dispositions: [.blocked(.init(
                selection: missing,
                explanation: "The selected transaction is missing."
            ))],
            rowChanges: [],
            metadata: .init(
                currency: .usd,
                accountNames: [:],
                payeeNames: [:],
                categoryNames: [:]
            ),
            clearTarget: nil,
            reviewFingerprint: "fingerprint",
            effectsDescription: "The batch is blocked.",
            authorization: nil,
            canSubmit: false
        )

        let display = TransactionBatchReviewDisplay(review: review)
        let row = try #require(display.rows.first)
        #expect(display.rows.count == 1)
        #expect(row.member == nil)
        #expect(row.status == "Blocked")
        #expect(row.explanation == "The selected transaction is missing.")
    }

    @Test func privacyReviewMasksIdentityNotesAndBeforeAfterAmounts() throws {
        let selected = try #require(TransactionSelectionIdentity(
            transactionID: "selected", familyRootID: "selected", role: .root
        ))
        let before = reviewRow(
            id: "selected", accountID: "checking", amount: -12_345,
            payeeID: "coffee", transferID: "paired", notes: "Private memo"
        )
        let after = row(before, amount: -20_000)
        let review = TransactionBatchReview(
            id: "review",
            context: makeContext(),
            intent: .delete,
            selections: [selected],
            dispositions: [.eligible(.init(
                selection: selected,
                affectedTransactionIDs: ["selected"],
                description: "Update the selected transaction."
            ))],
            rowChanges: [.init(before: before, after: after)],
            metadata: .init(
                currency: .usd,
                accountNames: ["checking": "Real Checking"],
                payeeNames: ["coffee": "Real Payee"],
                categoryNames: [:]
            ),
            clearTarget: nil,
            reviewFingerprint: "fingerprint",
            effectsDescription: "One row changes.",
            authorization: nil,
            canSubmit: true
        )

        let display = TransactionBatchReviewDisplay(review: review, isPrivacyModeEnabled: true)
        let member = try #require(display.rows.first?.member)
        #expect(member.payee != "Real Payee")
        #expect(!member.context.contains("Real Checking"))
        #expect(member.note == nil)
        #expect(member.amount == PrivacyDisplay.money(
            -12_345,
            seed: "batch-review-selected-identity--12345",
            currency: .usd
        ))
        let amountEffect = try #require(member.effects.first { $0.title == "Amount" })
        #expect(amountEffect.before == PrivacyDisplay.money(
            -12_345,
            seed: "batch-review-selected-before--12345",
            currency: .usd
        ))
        #expect(amountEffect.after == PrivacyDisplay.money(
            -20_000,
            seed: "batch-review-selected-after--20000",
            currency: .usd
        ))
    }

    private func makeContext() -> TransactionSelectionContext {
        TransactionSelectionContext(
            budgetID: "budget",
            sessionGeneration: 1,
            scope: .spending,
            querySignature: TransactionFeedQuery().signature
        )
    }

    private func transaction(id: String) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "account",
            date: "2026-09-01",
            amount: -100,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: nil,
            notes: nil,
            cleared: .bool(false)
        )
    }

    private func reviewRow(
        id: String,
        accountID: String,
        amount: Int,
        payeeID: String,
        transferID: String,
        notes: String? = nil
    ) -> TransactionBatchRowSnapshot {
        TransactionBatchRowSnapshot(
            id: id,
            accountID: accountID,
            dateValue: 20260703,
            amount: amount,
            payeeID: payeeID,
            categoryID: nil,
            notes: notes,
            cleared: false,
            reconciled: false,
            tombstone: false,
            isParent: false,
            isChild: false,
            parentID: nil,
            transferID: transferID,
            sortOrder: nil,
            startingBalance: false,
            splitError: nil,
            scheduleID: nil,
            importedID: nil,
            importedPayee: nil
        )
    }

    private func row(_ row: TransactionBatchRowSnapshot, amount: Int) -> TransactionBatchRowSnapshot {
        TransactionBatchRowSnapshot(
            id: row.id,
            accountID: row.accountID,
            dateValue: row.dateValue,
            amount: amount,
            payeeID: row.payeeID,
            categoryID: row.categoryID,
            notes: row.notes,
            cleared: row.cleared,
            reconciled: row.reconciled,
            tombstone: row.tombstone,
            isParent: row.isParent,
            isChild: row.isChild,
            parentID: row.parentID,
            transferID: row.transferID,
            sortOrder: row.sortOrder,
            startingBalance: row.startingBalance,
            splitError: row.splitError,
            scheduleID: row.scheduleID,
            importedID: row.importedID,
            importedPayee: row.importedPayee
        )
    }

    private func tombstoned(_ row: TransactionBatchRowSnapshot) -> TransactionBatchRowSnapshot {
        TransactionBatchRowSnapshot(
            id: row.id,
            accountID: row.accountID,
            dateValue: row.dateValue,
            amount: row.amount,
            payeeID: row.payeeID,
            categoryID: row.categoryID,
            notes: row.notes,
            cleared: row.cleared,
            reconciled: row.reconciled,
            tombstone: true,
            isParent: row.isParent,
            isChild: row.isChild,
            parentID: row.parentID,
            transferID: row.transferID,
            sortOrder: row.sortOrder,
            startingBalance: row.startingBalance,
            splitError: row.splitError,
            scheduleID: row.scheduleID,
            importedID: row.importedID,
            importedPayee: row.importedPayee
        )
    }
}

@MainActor
private final class DeferredFirstBatchReviewRepository: TransactionBatchRepositoryProtocol {
    private let firstRequestFails: Bool
    private let firstRequestEntered = TestLatch()
    private let releaseFirstRequestLatch = TestLatch()
    private var requestCount = 0

    init(firstRequestFails: Bool) {
        self.firstRequestFails = firstRequestFails
    }

    func waitForFirstRequest(timeout: Duration = .seconds(10)) async -> Bool {
        let reached = await firstRequestEntered.wait(timeout: timeout) { [releaseFirstRequestLatch] in
            releaseFirstRequestLatch.trip()
        }
        return requestCount > 0 && reached
    }

    func releaseFirstRequest() {
        releaseFirstRequestLatch.trip()
    }

    func reviewTransactionBatch(
        context: TransactionSelectionContext,
        intent: TransactionBatchIntent,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionBatchReview {
        requestCount += 1
        if requestCount == 1 {
            firstRequestEntered.trip()
            await releaseFirstRequestLatch.wait()
            if firstRequestFails { throw ReviewFailure.expected }
        }

        return TransactionBatchReview(
            id: "review-\(selections[0].transactionID)",
            context: context,
            intent: intent,
            selections: selections,
            dispositions: selections.map {
                .eligible(TransactionBatchEffectSummary(
                    selection: $0,
                    affectedTransactionIDs: [$0.transactionID],
                    description: "One row would be changed."
                ))
            },
            rowChanges: selections.map {
                let snapshot = rowSnapshot(id: $0.transactionID)
                return TransactionBatchRowChange(before: snapshot, after: snapshot)
            },
            metadata: reviewMetadata,
            clearTarget: nil,
            reviewFingerprint: "fingerprint-\(selections[0].transactionID)",
            effectsDescription: "One physical row is affected.",
            authorization: nil,
            canSubmit: true
        )
    }

    func commitTransactionBatch(
        review: TransactionBatchReview,
        authorization: TransactionBatchAuthorization?
    ) async throws -> TransactionBatchOutcome {
        throw ReviewFailure.expected
    }

    private func rowSnapshot(id: String) -> TransactionBatchRowSnapshot {
        TransactionBatchRowSnapshot(
            id: id,
            accountID: "account",
            dateValue: 20260901,
            amount: -100,
            payeeID: nil,
            categoryID: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            tombstone: false,
            isParent: false,
            isChild: false,
            parentID: nil,
            transferID: nil,
            sortOrder: nil,
            startingBalance: false,
            splitError: nil,
            scheduleID: nil,
            importedID: nil,
            importedPayee: nil
        )
    }

    private var reviewMetadata: TransactionBatchReviewMetadata {
        TransactionBatchReviewMetadata(
            currency: .usd,
            accountNames: ["account": "Checking"],
            payeeNames: [:],
            categoryNames: [:]
        )
    }

    private enum ReviewFailure: Error {
        case expected
    }
}
