import Foundation
import Testing
@testable import Actualist

struct TransactionCommandPresentationTests {
    @Test func duplicateFamilyDeduplicationMessageAppearsWhenSeveralSelectionsCollapse() throws {
        let parent = try identity("parent")
        let child = try identity("child", familyRootID: "parent", role: .child)
        let review = TransactionDuplicateReview(
            id: "review",
            context: makeCommandContext(),
            selections: [parent, child],
            groups: [
                TransactionDuplicateGroupReview(
                    id: "parent",
                    selectedTransactionIDs: ["parent", "child"],
                    sourceTransactionIDs: ["parent", "child"],
                    duplicateTransactionIDs: ["copy-parent", "copy-child"],
                    rows: [
                        duplicateRow(sourceID: "parent", isParent: true),
                        duplicateRow(sourceID: "child", isChild: true, parentID: "copy-parent"),
                    ]
                )
            ],
            allocations: [],
            affectedResources: ChangedResources(accounts: [], months: [], transactions: []),
            reviewFingerprint: "fingerprint",
            canSubmit: true
        )

        let display = TransactionDuplicateReviewDisplay(
            review: review,
            currency: .usd,
            locale: Locale(identifier: "en_US")
        )
        #expect(display.familyDeduplicationMessage == "2 selected transactions belong to one transaction, so Duplicate creates one copy.")
        #expect(display.copyCountText == "2")
        #expect(display.canSubmit)
        #expect(display.groups.first?.rows.map(\.role) == ["Split transaction", "Split entry"])
    }

    @Test func separateDuplicateSelectionsDoNotClaimFamilyDeduplication() throws {
        let first = try identity("first")
        let second = try identity("second")
        let review = TransactionDuplicateReview(
            id: "review",
            context: makeCommandContext(),
            selections: [first, second],
            groups: [
                duplicateGroup(id: "first", sourceID: "first"),
                duplicateGroup(id: "second", sourceID: "second"),
            ],
            allocations: [],
            affectedResources: ChangedResources(accounts: [], months: [], transactions: []),
            reviewFingerprint: "fingerprint",
            canSubmit: true
        )

        let display = TransactionDuplicateReviewDisplay(review: review, currency: .usd, locale: Locale(identifier: "en_US"))
        #expect(display.familyDeduplicationMessage == nil)
        #expect(display.groups.map(\.title) == ["New copy 1", "New copy 2"])
    }

    @Test func mergeLabelsInputOrderIndependentlyOfKeptAndDroppedRows() throws {
        let review = TransactionMergeReview(
            id: "review",
            context: makeCommandContext(),
            orderedTransactionIDs: ["later", "earlier"],
            keptRow: mergePresentationRow(id: "earlier", amount: 45_000, notes: "Paycheck"),
            droppedRow: mergePresentationRow(id: "later", amount: 45_000),
            fieldEffects: [
                TransactionMergeFieldEffect(
                    transactionID: "earlier",
                    field: .notes,
                    beforeValue: .text(nil),
                    droppedValue: .text("Paycheck"),
                    afterValue: .text("Paycheck"),
                    winner: .droppedFallback
                )
            ],
            childMovements: [],
            transferDisposition: .none,
            reciprocalTransferPairs: [],
            tombstonedTransactionIDs: ["later"],
            tombstonedPeerIDs: [],
            affectedResources: TransactionMergeAffectedResources(
                changed: ChangedResources(accounts: [], months: [], transactions: []),
                payeeIDs: [],
                categoryIDs: []
            ),
            blockedReason: nil,
            reconciledTransactionIDs: [],
            reviewFingerprint: "fingerprint"
        )

        let display = TransactionMergeReviewDisplay(review: review, locale: Locale(identifier: "en_US"), currency: .usd)
        #expect(display.inputs.map(\.positionLabel) == ["Input 1", "Input 2"])
        #expect(display.inputs.map(\.id) == ["later", "earlier"])
        #expect(display.inputs.map(\.outcomeLabel) == ["Dropped", "Kept"])
        #expect(display.keptLabel == "Input 2")
        #expect(display.droppedLabel == "Input 1")
        #expect(display.inputs[1].detail == "This transaction is kept.")
        #expect(display.inputs[1].amount == BudgetCurrency.usd.formatted(45_000))
        #expect(display.keptEffects.map(\.title) == ["Notes"])
        #expect(display.canSubmit)
    }

    @Test func blockedChildAndMalformedReasonsAppearBeforeConfirmation() {
        let child = blockedMergeDisplay(.selectedChild("child"))
        let malformed = blockedMergeDisplay(.malformedRow("row"))
        let split = blockedMergeDisplay(.malformedSplit("parent"))

        #expect(child.blockedMessage == "A split entry cannot be merged by itself. Select the whole transaction.")
        #expect(malformed.blockedMessage == "This transaction cannot be merged because one of its stored values is incomplete.")
        #expect(split.blockedMessage == "This split cannot be merged because its entries are incomplete.")
        #expect(child.canSubmit == false)
        #expect(malformed.canSubmit == false)
        #expect(child.authorizationMessage == nil)
        #expect(child.inputs.map(\.positionLabel) == ["Input 1", "Input 2"])
        #expect(child.inputs.allSatisfy { $0.outcomeLabel == nil })
    }

    @Test func blockedMergeStillShowsBothSelectedTransactions() {
        let display = blockedMergeDisplay(
            .amountMismatch,
            inputRows: [
                mergePresentationRow(id: "child", amount: -500, notes: "Lunch"),
                mergePresentationRow(id: "other", amount: -750)
            ]
        )

        #expect(display.blockedMessage == "These transactions have different amounts, so they cannot be merged.")
        #expect(display.canSubmit == false)
        #expect(display.inputs.map(\.amount) == [
            BudgetCurrency.usd.formatted(-500),
            BudgetCurrency.usd.formatted(-750)
        ])
        #expect(display.inputs.allSatisfy { $0.context == "Aug 15, 2026" && $0.role == "Transaction" })
        #expect(display.inputs.first?.note == "Lunch")
        #expect(display.inputs.allSatisfy { $0.detail == "This transaction will not be changed." })
        #expect(display.inputs.allSatisfy { $0.outcomeLabel == nil })
    }

    @Test func blockedMergeMarksOnlyAMissingInputUnavailable() {
        let display = blockedMergeDisplay(
            .missingRootSnapshot("other"),
            inputRows: [mergePresentationRow(id: "child", amount: -500)]
        )

        #expect(display.inputs.map(\.detail) == [
            "This transaction will not be changed.",
            "This transaction is unavailable."
        ])
        #expect(display.inputs.last?.amount == nil)
    }

    @Test func reconciledMergeUsesTheBatchConfirmationSentence() {
        let review = TransactionMergeReview(
            id: "review",
            context: makeCommandContext(),
            orderedTransactionIDs: ["first", "second"],
            keptRow: mergePresentationRow(id: "first", amount: -500),
            droppedRow: mergePresentationRow(id: "second", amount: -500),
            fieldEffects: [],
            childMovements: [],
            transferDisposition: .none,
            reciprocalTransferPairs: [],
            tombstonedTransactionIDs: ["second"],
            tombstonedPeerIDs: [],
            affectedResources: TransactionMergeAffectedResources(
                changed: ChangedResources(accounts: [], months: [], transactions: []),
                payeeIDs: [],
                categoryIDs: []
            ),
            blockedReason: nil,
            reconciledTransactionIDs: ["first", "paired"],
            reviewFingerprint: "fingerprint"
        )

        let display = TransactionMergeReviewDisplay(review: review, locale: Locale(identifier: "en_US"))
        #expect(display.authorizationMessage == "2 reconciled transactions are connected to these changes.")
        #expect(display.canSubmit)
        #expect(TransactionMergeCoordinator.authorization(for: review)?.reconciledTransactionIDs == ["first", "paired"])
    }

    @Test func privacyModeMasksDuplicateAndMergeAmounts() throws {
        let duplicate = TransactionDuplicateReviewDisplay(
            review: TransactionDuplicateReview(
                id: "review",
                context: makeCommandContext(),
                selections: [try identity("source")],
                groups: [duplicateGroup(id: "source", sourceID: "source")],
                allocations: [],
                affectedResources: ChangedResources(accounts: [], months: [], transactions: []),
                reviewFingerprint: "fingerprint",
                canSubmit: true
            ),
            currency: .usd,
            isPrivacyModeEnabled: true
        )
        let amount = try #require(duplicate.groups.first?.rows.first?.amount)
        #expect(amount != BudgetCurrency.usd.formatted(-1_250))
        #expect(amount == PrivacyDisplay.money(
            -1_250,
            seed: "duplicate-review-copy-source--1250",
            currency: .usd
        ))
    }
}

private func blockedMergeDisplay(
    _ reason: TransactionMergeBlockedReason,
    inputRows: [TransactionMergeReviewRow] = []
) -> TransactionMergeReviewDisplay {
    TransactionMergeReviewDisplay(
        review: TransactionMergeReview(
            id: "review",
            context: makeCommandContext(),
            orderedTransactionIDs: ["child", "other"],
            keptRow: nil,
            droppedRow: nil,
            fieldEffects: [],
            childMovements: [],
            transferDisposition: .none,
            reciprocalTransferPairs: [],
            tombstonedTransactionIDs: [],
            tombstonedPeerIDs: [],
            affectedResources: TransactionMergeAffectedResources(
                changed: ChangedResources(accounts: [], months: [], transactions: []),
                payeeIDs: [],
                categoryIDs: []
            ),
            blockedReason: reason,
            reconciledTransactionIDs: ["child"],
            reviewFingerprint: "fingerprint",
            inputRows: inputRows
        ),
        locale: Locale(identifier: "en_US")
    )
}

private func duplicateGroup(id: String, sourceID: String) -> TransactionDuplicateGroupReview {
    TransactionDuplicateGroupReview(
        id: id,
        selectedTransactionIDs: [sourceID],
        sourceTransactionIDs: [sourceID],
        duplicateTransactionIDs: ["copy-\(sourceID)"],
        rows: [duplicateRow(sourceID: sourceID)]
    )
}

private func duplicateRow(
    sourceID: String,
    isParent: Bool = false,
    isChild: Bool = false,
    parentID: String? = nil
) -> TransactionDuplicateReviewRow {
    TransactionDuplicateReviewRow(
        sourceTransactionID: sourceID,
        duplicateTransactionID: "copy-\(sourceID)",
        accountID: "checking",
        date: "2026-08-15",
        amountMinorUnits: -1_250,
        payeeID: nil,
        categoryID: nil,
        isParent: isParent,
        isChild: isChild,
        parentDuplicateTransactionID: parentID,
        transferDuplicateTransactionID: nil
    )
}

private func mergePresentationRow(id: String, amount: Int, notes: String? = nil) -> TransactionMergeReviewRow {
    TransactionMergeReviewRow(
        transactionID: id,
        accountID: "checking",
        date: "2026-08-15",
        amountMinorUnits: amount,
        payeeID: nil,
        categoryID: nil,
        notes: notes,
        cleared: false,
        reconciled: false,
        isParent: false,
        isChild: false,
        isTransfer: false
    )
}
