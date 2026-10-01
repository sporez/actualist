import Foundation
import Testing
@testable import Actualist

struct TransactionMergePlannerTests {
    @Test func keepDropPriorityUsesOrderedInputsAndKeepsImportedIdentity() throws {
        let importedID = transaction(
            "imported-id", dateValue: 20260922, cleared: false, reconciled: false,
            importedID: "bank-1", importedDescription: "kept description"
        )
        let importedPayee = transaction(
            "imported-payee", dateValue: 20260918, cleared: true, reconciled: true,
            importedPayee: "Bank Merchant", importedDescription: "dropped description"
        )
        let firstOrder = try #require(plan(importedID, importedPayee).plan)
        let reverseOrder = try #require(plan(importedPayee, importedID).plan)
        #expect(firstOrder.keptTransactionID == "imported-id")
        #expect(reverseOrder.keptTransactionID == "imported-id")
        #expect(firstOrder.afterSnapshots.first { $0.id == "imported-id" }?.importedID == "bank-1")
        #expect(firstOrder.afterSnapshots.first { $0.id == "imported-id" }?.importedPayee == nil)
        #expect(firstOrder.afterSnapshots.first { $0.id == "imported-id" }?.importedDescription == "kept description")
        #expect(firstOrder.afterSnapshots.first { $0.id == "imported-id" }?.cleared == true)
        #expect(firstOrder.afterSnapshots.first { $0.id == "imported-id" }?.reconciled == true)

        let manual = transaction("manual")
        let imported = transaction("imported", importedID: "bank-2")
        #expect(plan(manual, imported).plan?.keptTransactionID == "imported")
        #expect(plan(imported, manual).plan?.keptTransactionID == "imported")
        let importedByPayee = transaction("payee", importedPayee: "Payee")
        #expect(plan(manual, importedByPayee).plan?.keptTransactionID == "payee")
        #expect(plan(importedByPayee, manual).plan?.keptTransactionID == "payee")
    }

    @Test func earlierDateAndExactTieKeepTheExpectedOrderedInput() throws {
        let earlier = transaction("earlier", dateValue: 20260918)
        let later = transaction("later", dateValue: 20260922)
        #expect(plan(earlier, later).plan?.keptTransactionID == "earlier")
        #expect(plan(later, earlier).plan?.keptTransactionID == "earlier")

        let first = transaction("first", dateValue: 20260920)
        let second = transaction("second", dateValue: 20260920)
        #expect(plan(first, second).plan?.keptTransactionID == "second")
        #expect(plan(second, first).plan?.keptTransactionID == "first")
    }

    @Test func simpleRowsRemainSimpleAndNoTransferDispositionIsReported() throws {
        let planned = try #require(plan(transaction("plain-a"), transaction("plain-b")).plan)
        let snapshots = Dictionary(uniqueKeysWithValues: planned.afterSnapshots.map { ($0.id, $0) })
        #expect(planned.transferDisposition == .none)
        #expect(planned.reciprocalTransferPairs.isEmpty)
        #expect(planned.keptTransactionID == "plain-b")
        #expect(planned.droppedTransactionID == "plain-a")
        #expect(snapshots["plain-a"]?.isParent == false)
        #expect(snapshots["plain-a"]?.tombstone == true)
        #expect(snapshots["plain-b"]?.tombstone == false)
    }

    @Test func emptyStringFallsBackButWhitespaceRemainsTruthy() throws {
        let keeper = transaction(
            "keeper",
            payeeID: "",
            categoryID: "",
            notes: "",
            scheduleID: " ",
            importedID: "bank-keeper"
        )
        let dropped = transaction(
            "dropped",
            payeeID: " merchant ",
            categoryID: " category ",
            notes: "  ",
            scheduleID: "schedule-drop"
        )
        let planned = try #require(plan(keeper, dropped).plan)
        let merged = try #require(planned.afterSnapshots.first { $0.id == "keeper" })
        #expect(merged.payeeID == " merchant ")
        #expect(merged.categoryID == " category ")
        #expect(merged.notes == "  ")
        #expect(merged.scheduleID == " ")

        let clearedFallback = try #require(plan(
            transaction("false-cleared", cleared: false, reconciled: true, importedID: "bank-false"),
            transaction("nil-cleared", cleared: nil, reconciled: false)
        ).plan)
        let statusKeeper = try #require(clearedFallback.afterSnapshots.first { $0.id == "false-cleared" })
        #expect(statusKeeper.cleared == nil)
        #expect(statusKeeper.reconciled == true)

        let emptyKeeper = transaction("empty-keeper", notes: "", importedID: "bank-empty")
        let noDroppedValue = transaction("nil-notes", notes: nil)
        #expect(try #require(plan(emptyKeeper, noDroppedValue).plan)
            .afterSnapshots.first { $0.id == "empty-keeper" }?.notes == nil)
    }

    @Test func simpleKeeperAdoptsOneChildFamilyUnderRuleA() throws {
        let keeper = transaction("simple", dateValue: 20260919, payeeID: "merchant", categoryID: "food")
        let (splitRoot, child) = splitFamily(rootID: "split", childIDs: ["split-child"])
        let result = plan(keeper, splitRoot, secondExtras: [child])
        let planned = try #require(result.plan)
        let newParent = try #require(planned.afterSnapshots.first { $0.id == "simple" })
        let movedChild = try #require(planned.afterSnapshots.first { $0.id == "split-child" })
        #expect(newParent.isParent == true)
        #expect(newParent.categoryID == nil)
        #expect(newParent.payeeID == "merchant")
        #expect(movedChild.parentID == "simple")
        #expect(movedChild.tombstone != true)
        #expect(planned.afterSnapshots.first { $0.id == "split" }?.tombstone == true)
        #expect(planned.childMovements == [TransactionMergeChildMovement(
            childID: "split-child", originalParentID: "split", newParentID: "simple"
        )])
    }

    @Test func simpleKeeperAdoptsSplitChildAndPreservesItsReciprocalTransfer() throws {
        let simple = transaction("simple-transfer-adopter", dateValue: 20260918)
        let (splitRoot, child) = splitFamily(rootID: "split-transfer-parent", childIDs: ["transfer-child"])
        let transferChild = withTransfer(child, peerID: "transfer-peer", payeeID: "payee-to-target")
        let peer = transaction("transfer-peer", accountID: "target", amount: 1000,
                               payeeID: "payee-to-main", categoryID: nil, transferID: "transfer-child")
        let planned = try #require(plan(
            simple,
            splitRoot,
            secondExtras: [transferChild, peer]
        ).plan)
        let after = Dictionary(uniqueKeysWithValues: planned.afterSnapshots.map { ($0.id, $0) })
        #expect(planned.keptTransactionID == simple.id)
        #expect(after["simple-transfer-adopter"]?.isParent == true)
        #expect(after["simple-transfer-adopter"]?.categoryID == nil)
        #expect(after["transfer-child"]?.parentID == simple.id)
        #expect(after["transfer-child"]?.transferID == "transfer-peer")
        #expect(after["transfer-peer"]?.transferID == "transfer-child")
        #expect(planned.reciprocalTransferPairs == [TransactionMergeTransferPair("transfer-child", "transfer-peer")])
    }

    @Test func retainedSplitParentCannotAcquireCategoryOrPayeeFromSimpleRow() throws {
        let (splitRoot, child) = splitFamily(rootID: "split-keeper", childIDs: ["split-child"])
        let keeper = withImportedID(splitRoot, "bank-split")
        let simpleWithPayee = transaction("simple-payee-drop", payeeID: "merchant", categoryID: nil)
        let payeeResult = plan(keeper, simpleWithPayee, firstExtras: [child])
        #expect(payeeResult.plan == nil)
        #expect(payeeResult.blockedReason == .invalidProposedParentFields("split-keeper"))

        let simpleWithCategory = transaction("simple-category-drop", payeeID: nil, categoryID: "food")
        let categoryResult = plan(keeper, simpleWithCategory, firstExtras: [child])
        #expect(categoryResult.plan == nil)
        #expect(categoryResult.blockedReason == .invalidProposedParentFields("split-keeper"))

        let keeperWithPayee = withImportedID(
            copying(splitRoot, payeeID: .value("existing-parent-payee")),
            "bank-split-with-payee"
        )
        let simpleWithoutParentFields = transaction("simple-no-parent-fields", payeeID: nil, categoryID: nil)
        let retainedPayeeResult = try #require(plan(
            keeperWithPayee,
            simpleWithoutParentFields,
            firstExtras: [child]
        ).plan)
        #expect(retainedPayeeResult.afterSnapshots.first { $0.id == keeperWithPayee.id }?.payeeID == "existing-parent-payee")

        let falseySimple = transaction("simple-falsey-drop", payeeID: "", categoryID: nil)
        let falseyResult = try #require(plan(keeper, falseySimple, firstExtras: [child]).plan)
        #expect(falseyResult.afterSnapshots.first { $0.id == keeper.id }?.payeeID == "")
    }

    @Test func adoptingSplitCannotAcquireANewParentPayeeFromTheDroppedFamily() throws {
        let simple = transaction("simple", dateValue: 20260918, payeeID: nil, categoryID: nil)
        let (splitRoot, child) = splitFamily(rootID: "split", childIDs: ["split-child"])
        let sourceParentWithPayee = copying(splitRoot, payeeID: .value("split-payee"))
        let result = plan(simple, sourceParentWithPayee, secondExtras: [child])
        #expect(result.plan == nil)
        #expect(result.blockedReason == .invalidProposedParentFields("simple"))
    }

    @Test func completeSplitFamilyDropTombstonesParentAndEveryChild() throws {
        let (keepRoot, keepChildren) = splitFamilyGraph(
            rootID: "keep-root",
            childAmounts: [("keep-child-a", -400), ("keep-child-b", -600)]
        )
        let importedKeepRoot = withImportedID(keepRoot, "bank-keep")
        let (dropRoot, dropChildren) = splitFamilyGraph(
            rootID: "drop-root",
            childAmounts: [("drop-child-a", -400), ("drop-child-b", -600)]
        )
        let planned = try #require(plan(
            importedKeepRoot,
            dropRoot,
            firstExtras: keepChildren,
            secondExtras: dropChildren
        ).plan)
        #expect(Set(planned.tombstonedTransactionIDs) == ["drop-root", "drop-child-a", "drop-child-b"])
        #expect(planned.afterSnapshots.first { $0.id == "keep-child-a" }?.tombstone != true)
        #expect(planned.afterSnapshots.first { $0.id == "keep-child-b" }?.tombstone != true)
        #expect(planned.afterSnapshots.first { $0.id == "drop-child-a" }?.parentID == "drop-root")
        #expect(planned.afterSnapshots.first { $0.id == "drop-child-b" }?.parentID == "drop-root")
    }

    @Test func selectedChildZeroChildErrorAndMalformedFamiliesBlock() throws {
        let (root, child) = splitFamily(rootID: "root", childIDs: ["child"])
        #expect(plan(child, transaction("other"), firstExtras: [root]).blockedReason == .selectedChild("child"))

        let emptyParent = transaction("empty-parent", payeeID: nil, categoryID: nil, isParent: true)
        #expect(plan(emptyParent, transaction("other")).blockedReason == .zeroChildSplit("empty-parent"))

        let erroredParent = transaction("error-parent", payeeID: nil, categoryID: nil,
                                        isParent: true, splitError: "{\"difference\":1}")
        let errorChild = transaction("error-child", amount: -1000, categoryID: nil,
                                     isChild: true, parentID: "error-parent")
        #expect(plan(erroredParent, transaction("other"), firstExtras: [errorChild])
            .blockedReason == .splitHasError("error-parent"))

        let missingParentChild = transaction("orphan", isChild: true, parentID: "missing")
        #expect(plan(missingParentChild, transaction("other"))
            .blockedReason == .selectedChild("orphan"))
        let imbalancedChild = transaction("bad-child", amount: -500, categoryID: nil,
                                           isChild: true, parentID: "bad-parent")
        let badParent = transaction("bad-parent", amount: -1000, payeeID: nil,
                                    categoryID: nil, isParent: true)
        #expect(plan(badParent, transaction("other"), firstExtras: [imbalancedChild])
            .blockedReason == .malformedSplit("bad-parent"))

        let malformedParent = transaction("malformed-parent", payeeID: nil, categoryID: nil, isParent: true)
        let falselyParented = transaction("not-a-child", categoryID: nil, parentID: "malformed-parent")
        #expect(plan(malformedParent, transaction("other"), firstExtras: [falselyParented])
            .blockedReason == .malformedSplit("not-a-child"))
    }

    @Test func transferAdoptionUsesDestinationBudgetStatusForCategory() throws {
        for (destination, isOffBudget, expectedCategory) in [
            ("target", false, nil as String?),
            ("off", true, "food" as String?),
        ] {
            let (transferRoot, peer) = transferPair(
                rootID: "transfer-\(destination)",
                peerID: "peer-\(destination)",
                destinationAccountID: destination
            )
            let simple = transaction("simple-\(destination)", dateValue: 20260918,
                                     payeeID: "merchant", categoryID: "food")
            let planned = try #require(plan(
                simple,
                transferRoot,
                secondExtras: [peer],
                reference: reference(destinationIsOffBudget: isOffBudget)
            ).plan)
            let kept = try #require(planned.afterSnapshots.first { $0.id == simple.id })
            let keptPeer = try #require(planned.afterSnapshots.first { $0.id == peer.id })
            #expect(planned.keptTransactionID == simple.id)
            #expect(kept.transferID == peer.id)
            #expect(kept.payeeID == transferRoot.payeeID)
            #expect(kept.categoryID == expectedCategory)
            #expect(keptPeer.transferID == simple.id)
            #expect(planned.afterSnapshots.first { $0.id == transferRoot.id }?.tombstone == true)
            #expect(planned.transferDisposition == .adoptedPair(
                peerID: peer.id,
                destinationAccountID: destination
            ))
        }
    }

    @Test func sameDestinationTransferPairsKeepInputTwoAndDropTheOtherPair() throws {
        let (rootA, peerA) = transferPair(rootID: "root-a", peerID: "peer-a")
        let (rootB, peerB) = transferPair(rootID: "root-b", peerID: "peer-b")
        let planned = try #require(plan(
            rootA,
            rootB,
            firstExtras: [peerA],
            secondExtras: [peerB]
        ).plan)
        #expect(planned.keptTransactionID == "root-b")
        #expect(planned.droppedTransactionID == "root-a")
        #expect(planned.transferDisposition == .mergedPairs(
            keptPeerID: "peer-b",
            droppedPeerID: "peer-a",
            destinationAccountID: "target"
        ))
        #expect(planned.afterSnapshots.first { $0.id == "root-b" }?.categoryID == "food")
        #expect(Set(planned.tombstonedTransactionIDs) == ["root-a", "peer-a"])
        #expect(planned.reciprocalTransferPairs == [TransactionMergeTransferPair("peer-b", "root-b")])
    }

    @Test func differentTransferDestinationsAndBrokenPairsBlockWithoutAPlan() throws {
        let (rootA, peerA) = transferPair(rootID: "root-a", peerID: "peer-a")
        let (rootB, peerB) = transferPair(
            rootID: "root-b", peerID: "peer-b", destinationAccountID: "off"
        )
        let different = plan(rootA, rootB, firstExtras: [peerA], secondExtras: [peerB],
                             reference: reference(destinationIsOffBudget: true))
        #expect(different.plan == nil)
        #expect(different.blockedReason == .differentTransferDestinations)

        let missingPeerRoot = transaction("orphan-root", payeeID: "payee-to-target", transferID: "missing-peer")
        let missing = plan(missingPeerRoot, transaction("simple"))
        #expect(missing.plan == nil)
        #expect(missing.blockedReason == .malformedTransfer("orphan-root"))

        let nonreciprocalPeer = copying(peerA, transferID: .value("wrong-backlink"))
        let nonreciprocal = plan(rootA, transaction("simple"), firstExtras: [nonreciprocalPeer])
        #expect(nonreciprocal.plan == nil)
        #expect(nonreciprocal.blockedReason == .malformedTransfer("peer-a"))

        let wrongAmountPeer = copying(peerA, amount: .value(900))
        #expect(plan(rootA, transaction("amount-simple"), firstExtras: [wrongAmountPeer])
            .blockedReason == .malformedTransfer("peer-a"))
        let sameAccountPeer = copying(peerA, accountID: .value("main"))
        #expect(plan(rootA, transaction("account-simple"), firstExtras: [sameAccountPeer])
            .blockedReason == .malformedTransfer("peer-a"))

        let extraIncoming = transaction("extra", amount: 1000, transferID: "peer-a")
        let extra = plan(rootA, transaction("simple"), firstExtras: [peerA, extraIncoming])
        #expect(extra.plan == nil)
        #expect(extra.blockedReason == .extraIncomingTransfer("peer-a"))

        let noTransferDestination = TransactionMergeReferenceMetadata(
            accounts: reference().accounts,
            transferPayeeDestinations: [
                TransactionMergePayeeDestination(payeeID: "payee-to-main", accountID: "main")
            ]
        )
        #expect(plan(rootA, transaction("no-destination-simple"), firstExtras: [peerA],
                     reference: noTransferDestination).blockedReason == .missingTransferDestination("root-a"))
    }

    @Test func splitTransferWholeGraphDropAndReconciliationIncludeEveryPeer() throws {
        let (rootA, childA) = splitFamily(rootID: "split-a", childIDs: ["child-a"], amount: -1000)
        let (rootB, childB) = splitFamily(rootID: "split-b", childIDs: ["child-b"], amount: -1000)
        let reconciledRootA = withReconciled(rootA, true)
        let (peerA, _) = transferPair(rootID: "peer-a", peerID: "unneeded-a",
                                      sourceAccountID: "target", destinationAccountID: "main", amount: 1000)
        let (peerB, _) = transferPair(rootID: "peer-b", peerID: "unneeded-b",
                                      sourceAccountID: "target", destinationAccountID: "main", amount: 1000)
        // These are the reciprocal rows for the split children, not extra pairs.
        let transferChildA = withReconciled(
            withTransfer(childA, peerID: "peer-a", payeeID: "payee-to-target"), true
        )
        let transferChildB = withTransfer(childB, peerID: "peer-b", payeeID: "payee-to-target")
        let reciprocalPeerA = withReconciled(
            withTransfer(peerA, peerID: "child-a", payeeID: "payee-to-main"), true
        )
        let reciprocalPeerB = withTransfer(peerB, peerID: "child-b", payeeID: "payee-to-main")
        let planned = try #require(plan(
            reconciledRootA,
            rootB,
            firstExtras: [transferChildA, reciprocalPeerA],
            secondExtras: [transferChildB, reciprocalPeerB]
        ).plan)
        #expect(planned.keptTransactionID == "split-b")
        #expect(Set(planned.tombstonedTransactionIDs) == ["split-a", "child-a", "peer-a"])
        #expect(planned.tombstonedPeerIDs == ["child-a", "peer-a"])
        #expect(planned.reconciledTransactionIDs == ["child-a", "peer-a", "split-a"])
        #expect(planned.reciprocalTransferPairs == [TransactionMergeTransferPair("child-b", "peer-b")])
        let afterByID = Dictionary(uniqueKeysWithValues: planned.afterSnapshots.map { ($0.id, $0) })
        let keptRoot = try #require(afterByID["split-b"])
        let keptChild = try #require(afterByID["child-b"])
        let keptPeer = try #require(afterByID["peer-b"])
        #expect(keptRoot.isParent == true)
        #expect(keptChild.parentID == keptRoot.id)
        #expect(keptRoot.amount == keptChild.amount)
        #expect(keptChild.transferID == keptPeer.id)
        #expect(keptPeer.transferID == keptChild.id)
    }

    @Test func splitPeerCannotAcquireACategoryFromTheDroppedPeer() throws {
        let (rootA, peerA) = transferPair(rootID: "root-a", peerID: "peer-a")
        let peerAChild = transaction("peer-a-child", accountID: "target", amount: 1000,
                                     categoryID: nil, isChild: true, parentID: "peer-a")
        let (rootB, _) = transferPair(rootID: "root-b", peerID: "peer-b")
        let splitPeerA = copying(
            peerA,
            dateValue: .value(20260918),
            categoryID: .value(nil),
            isParent: .value(true)
        )
        let categorizedSimplePeer = transaction("peer-b", accountID: "target", dateValue: 20260922, amount: 1000,
                                                payeeID: "payee-to-main", categoryID: "food",
                                                transferID: "root-b")
        let result = plan(
            rootA,
            rootB,
            firstExtras: [splitPeerA, peerAChild],
            secondExtras: [categorizedSimplePeer]
        )
        #expect(result.plan == nil)
        #expect(result.blockedReason == .invalidProposedParentFields("peer-a"))
    }

    @Test func invalidSecondTransferPairBlocksTheWholePlan() throws {
        let (rootA, peerA) = transferPair(rootID: "root-a", peerID: "peer-a")
        let (rootB, peerB) = transferPair(rootID: "root-b", peerID: "peer-b")
        let invalidPeerB = copying(peerB, amount: .value(999))
        let result = plan(
            rootA,
            rootB,
            firstExtras: [peerA],
            secondExtras: [invalidPeerB]
        )
        #expect(result.plan == nil)
        #expect(result.blockedReason == .malformedTransfer("peer-b"))
    }

    @Test func inputRequiresTwoUniqueDisjointRootGraphsAndExplicitMetadata() {
        let a = transaction("a")
        let b = transaction("b")
        #expect(planIDs([], first: [a], second: [b]).blockedReason == .requiresExactlyTwoIDs)
        #expect(planIDs(["a"], first: [a], second: [b]).blockedReason == .requiresExactlyTwoIDs)
        #expect(planIDs(["", "b"], first: [a], second: [b]).blockedReason == .emptyTransactionID)
        #expect(planIDs(["a", "a"], first: [a], second: [b]).blockedReason == .duplicateTransactionID)
        #expect(planIDs(["a", "b"], first: [a, b], second: [b]).blockedReason == .overlappingGraphs(["b"]))
        #expect(planIDs(["a", "b"], first: [a, transaction("unrelated")], second: [b])
            .blockedReason == .malformedRow("unrelated"))

        let noAccount = TransactionMergeReferenceMetadata(accounts: [], transferPayeeDestinations: [])
        #expect(planIDs(["a", "b"], first: [a], second: [b], reference: noAccount)
            .blockedReason == .missingAccountMetadata("main"))
        #expect(plan(transaction("other-account", accountID: "savings"), b)
            .blockedReason == .accountMismatch)
        #expect(plan(a, transaction("different-amount", amount: -900))
            .blockedReason == .amountMismatch)
    }

    private func plan(
        _ first: TransactionBatchTransactionSnapshot,
        _ second: TransactionBatchTransactionSnapshot,
        firstExtras: [TransactionBatchTransactionSnapshot] = [],
        secondExtras: [TransactionBatchTransactionSnapshot] = [],
        reference: TransactionMergeReferenceMetadata? = nil
    ) -> TransactionMergePlanningResult {
        TransactionMergePlanner.plan(TransactionMergePlannerInput(
            orderedTransactionIDs: [first.id, second.id],
            firstGraph: [first] + firstExtras,
            secondGraph: [second] + secondExtras,
            referenceMetadata: reference ?? self.reference()
        ))
    }

    private func planIDs(
        _ ids: [String],
        first: [TransactionBatchTransactionSnapshot],
        second: [TransactionBatchTransactionSnapshot],
        reference: TransactionMergeReferenceMetadata? = nil
    ) -> TransactionMergePlanningResult {
        TransactionMergePlanner.plan(TransactionMergePlannerInput(
            orderedTransactionIDs: ids,
            firstGraph: first,
            secondGraph: second,
            referenceMetadata: reference ?? self.reference()
        ))
    }

    private func transaction(
        _ id: String,
        accountID: String = "main",
        dateValue: Int = 20260920,
        amount: Int = -1000,
        payeeID: String? = "merchant",
        categoryID: String? = "food",
        notes: String? = "note",
        cleared: Bool? = false,
        reconciled: Bool? = false,
        isParent: Bool? = false,
        isChild: Bool? = false,
        parentID: String? = nil,
        transferID: String? = nil,
        splitError: String? = nil,
        scheduleID: String? = nil,
        importedID: String? = nil,
        importedPayee: String? = nil,
        importedDescription: String? = nil,
        tombstone: Bool? = false,
        startingBalance: Bool? = false,
        sortOrder: Double? = 100
    ) -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: id,
            columns: ["account", "date", "amount", "payee", "category", "notes", "cleared",
                      "reconciled", "tombstone", "is_parent", "is_child", "parent_id", "transfer_id",
                      "sort_order", "starting_balance_flag", "error", "schedule", "financial_id",
                      "imported_payee", "imported_description"],
            accountID: accountID,
            dateValue: dateValue,
            amount: amount,
            payeeID: payeeID,
            categoryID: categoryID,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            tombstone: tombstone,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID,
            transferID: transferID,
            sortOrder: sortOrder,
            splitError: splitError,
            startingBalance: startingBalance,
            scheduleID: scheduleID,
            importedID: importedID,
            importedPayee: importedPayee,
            importedDescription: importedDescription
        )
    }

    private func splitFamily(
        rootID: String,
        childIDs: [String],
        amount: Int = -1000
    ) -> (TransactionBatchTransactionSnapshot, TransactionBatchTransactionSnapshot) {
        precondition(childIDs.count == 1, "this focused helper models the admitted one-child cases")
        let root = transaction(rootID, amount: amount, payeeID: nil, categoryID: nil, isParent: true)
        let child = transaction(childIDs[0], amount: amount, payeeID: "merchant", categoryID: "food",
                                isChild: true, parentID: rootID, sortOrder: -1)
        return (root, child)
    }

    private func splitFamilyGraph(
        rootID: String,
        childAmounts: [(id: String, amount: Int)]
    ) -> (TransactionBatchTransactionSnapshot, [TransactionBatchTransactionSnapshot]) {
        let parentAmount = childAmounts.reduce(into: 0) { $0 += $1.amount }
        let root = transaction(rootID, amount: parentAmount, payeeID: nil, categoryID: nil, isParent: true)
        let children = childAmounts.map { child in
            transaction(child.id, amount: child.amount, payeeID: "merchant", categoryID: "food",
                        isChild: true, parentID: rootID, sortOrder: -1)
        }
        return (root, children)
    }

    private func transferPair(
        rootID: String,
        peerID: String,
        sourceAccountID: String = "main",
        destinationAccountID: String = "target",
        amount: Int = -1000
    ) -> (TransactionBatchTransactionSnapshot, TransactionBatchTransactionSnapshot) {
        let destinationPayeeID = transferPayee(for: destinationAccountID)
        let reversePayeeID = transferPayee(for: sourceAccountID)
        let root = transaction(rootID, accountID: sourceAccountID, amount: amount,
                               payeeID: destinationPayeeID, categoryID: "food", transferID: peerID)
        let peer = transaction(peerID, accountID: destinationAccountID, amount: -amount,
                               payeeID: reversePayeeID, categoryID: nil, transferID: rootID)
        return (root, peer)
    }

    private func transferPayee(for accountID: String) -> String {
        switch accountID {
        case "main": "payee-to-main"
        case "off": "payee-to-off"
        default: "payee-to-target"
        }
    }

    private enum SnapshotPatch<Value> {
        case unchanged
        case value(Value?)
    }

    private func value<Value>(_ patch: SnapshotPatch<Value>, replacing original: Value?) -> Value? {
        switch patch {
        case .unchanged: original
        case .value(let replacement): replacement
        }
    }

    private func copying(
        _ snapshot: TransactionBatchTransactionSnapshot,
        accountID: SnapshotPatch<String> = .unchanged,
        dateValue: SnapshotPatch<Int> = .unchanged,
        amount: SnapshotPatch<Int> = .unchanged,
        payeeID: SnapshotPatch<String> = .unchanged,
        categoryID: SnapshotPatch<String> = .unchanged,
        notes: SnapshotPatch<String> = .unchanged,
        cleared: SnapshotPatch<Bool> = .unchanged,
        reconciled: SnapshotPatch<Bool> = .unchanged,
        tombstone: SnapshotPatch<Bool> = .unchanged,
        isParent: SnapshotPatch<Bool> = .unchanged,
        isChild: SnapshotPatch<Bool> = .unchanged,
        parentID: SnapshotPatch<String> = .unchanged,
        transferID: SnapshotPatch<String> = .unchanged,
        splitError: SnapshotPatch<String> = .unchanged,
        sortOrder: SnapshotPatch<Double> = .unchanged,
        startingBalance: SnapshotPatch<Bool> = .unchanged,
        scheduleID: SnapshotPatch<String> = .unchanged,
        importedID: SnapshotPatch<String> = .unchanged,
        importedPayee: SnapshotPatch<String> = .unchanged,
        importedDescription: SnapshotPatch<String> = .unchanged
    ) -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: snapshot.id,
            columns: snapshot.columns,
            accountID: value(accountID, replacing: snapshot.accountID),
            dateValue: value(dateValue, replacing: snapshot.dateValue),
            amount: value(amount, replacing: snapshot.amount),
            payeeID: value(payeeID, replacing: snapshot.payeeID),
            categoryID: value(categoryID, replacing: snapshot.categoryID),
            notes: value(notes, replacing: snapshot.notes),
            cleared: value(cleared, replacing: snapshot.cleared),
            reconciled: value(reconciled, replacing: snapshot.reconciled),
            tombstone: value(tombstone, replacing: snapshot.tombstone),
            isParent: value(isParent, replacing: snapshot.isParent),
            isChild: value(isChild, replacing: snapshot.isChild),
            parentID: value(parentID, replacing: snapshot.parentID),
            transferID: value(transferID, replacing: snapshot.transferID),
            sortOrder: value(sortOrder, replacing: snapshot.sortOrder),
            splitError: value(splitError, replacing: snapshot.splitError),
            startingBalance: value(startingBalance, replacing: snapshot.startingBalance),
            scheduleID: value(scheduleID, replacing: snapshot.scheduleID),
            importedID: value(importedID, replacing: snapshot.importedID),
            importedPayee: value(importedPayee, replacing: snapshot.importedPayee),
            importedDescription: value(importedDescription, replacing: snapshot.importedDescription)
        )
    }

    private func withImportedID(
        _ snapshot: TransactionBatchTransactionSnapshot,
        _ importedID: String
    ) -> TransactionBatchTransactionSnapshot {
        copying(snapshot, importedID: .value(importedID))
    }

    private func withReconciled(
        _ snapshot: TransactionBatchTransactionSnapshot,
        _ reconciled: Bool
    ) -> TransactionBatchTransactionSnapshot {
        copying(snapshot, reconciled: .value(reconciled))
    }

    private func withTransfer(
        _ snapshot: TransactionBatchTransactionSnapshot,
        peerID: String,
        payeeID: String
    ) -> TransactionBatchTransactionSnapshot {
        copying(snapshot, payeeID: .value(payeeID), transferID: .value(peerID))
    }

    private func reference(
        destinationIsOffBudget: Bool = false
    ) -> TransactionMergeReferenceMetadata {
        TransactionMergeReferenceMetadata(
            accounts: [
                TransactionMergeAccountMetadata(id: "main", isOffBudget: false),
                TransactionMergeAccountMetadata(id: "target", isOffBudget: false),
                TransactionMergeAccountMetadata(id: "off", isOffBudget: destinationIsOffBudget),
                TransactionMergeAccountMetadata(id: "savings", isOffBudget: false),
            ],
            transferPayeeDestinations: [
                TransactionMergePayeeDestination(payeeID: "payee-to-target", accountID: "target"),
                TransactionMergePayeeDestination(payeeID: "payee-to-main", accountID: "main"),
                TransactionMergePayeeDestination(payeeID: "payee-to-off", accountID: "off"),
            ]
        )
    }
}
