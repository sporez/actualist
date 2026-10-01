import Foundation
import Testing
@testable import Actualist

struct TransactionDuplicatePlannerTests {
    @Test func duplicatesSimpleRowWithFreshIdentityOrderAndResetStatus() throws {
        let source = transaction("simple", account: "checking", amount: -1_200)
        let allocation = TransactionDuplicateAllocation(
            sourceTransactionID: source.id,
            duplicateTransactionID: "simple-copy",
            sortOrder: 1_000
        )

        let plan = try TransactionDuplicatePlanner.plan(
            selections: [source.id],
            sourceSnapshots: [source],
            allocations: [allocation]
        )

        let duplicate = try #require(plan.afterSnapshots.first)
        #expect(plan.beforeSnapshots == [source])
        #expect(plan.rowChanges.count == 1)
        #expect(plan.rowChanges[0].before == source)
        #expect(plan.rowChanges[0].duplicate == duplicate)
        #expect(duplicate.id == "simple-copy")
        #expect(duplicate.sortOrder == 1_000)
        #expect(duplicate.cleared == false)
        #expect(duplicate.reconciled == false)
        #expect(duplicate.tombstone == false)
        #expect(duplicate.accountID == source.accountID)
        #expect(duplicate.dateValue == source.dateValue)
        #expect(duplicate.amount == source.amount)
        #expect(plan.requestsCategoryLearning == false)
        #expect(plan.affectedResources.accounts == ["checking"])
        #expect(plan.affectedResources.months == ["2026-09"])
        #expect(plan.affectedResources.transactions == ["simple", "simple-copy"])
    }

    @Test func duplicateReviewRetainsExactPreallocatedIDsAndDoubleOrders() throws {
        let selection = try #require(TransactionSelectionIdentity(
            transactionID: "source",
            familyRootID: "source",
            role: .root
        ))
        let allocation = TransactionDuplicateAllocation(
            sourceTransactionID: "source",
            duplicateTransactionID: "clone",
            sortOrder: 1_789_345_678_901.375
        )
        let review = TransactionDuplicateReview(
            id: "review",
            context: TransactionSelectionContext(
                budgetID: "budget",
                sessionGeneration: 1,
                scope: .spending,
                querySignature: TransactionFeedQuery().signature
            ),
            selections: [selection],
            groups: [],
            allocations: [allocation],
            affectedResources: ChangedResources(
                accounts: ["checking"],
                months: ["2026-09"],
                transactions: ["source", "clone"]
            ),
            reviewFingerprint: "stable-fingerprint",
            canSubmit: true
        )

        #expect(review.allocations == [allocation])
        #expect(review.allocations[0].sortOrder.bitPattern == allocation.sortOrder.bitPattern)
    }

    @Test func selectingSplitRootClonesCompleteFamilyWithFreshParentLinks() throws {
        let parent = transaction("parent", amount: -1_000, isParent: true)
        let first = transaction("child-a", amount: -400, isChild: true, parentID: parent.id)
        let second = transaction("child-b", amount: -600, isChild: true, parentID: parent.id)
        let sources = [parent, first, second]
        let plan = try duplicatePlan(sources, selections: [parent.id])

        #expect(plan.afterSnapshots.count == 3)
        #expect(plan.groups.count == 1)
        #expect(plan.groups[0].sourceTransactionIDs == ["child-a", "child-b", "parent"])
        #expect(plan.groups[0].sourceRootTransactionIDs == ["parent"])
        let copies = Dictionary(uniqueKeysWithValues: plan.afterSnapshots.map { ($0.id, $0) })
        let copiedParent = try #require(copies["copy-parent"])
        #expect(copiedParent.isParent == true)
        #expect(copiedParent.parentID == nil)
        #expect(copies["copy-child-a"]?.isChild == true)
        #expect(copies["copy-child-a"]?.parentID == copiedParent.id)
        #expect(copies["copy-child-b"]?.parentID == copiedParent.id)
        #expect(copies.values.allSatisfy { $0.cleared == false && $0.reconciled == false })
    }

    @Test func selectingChildDuplicatesWholeFamilyAndOverlappingSelectionsDeduplicate() throws {
        let parent = transaction("parent", amount: -1_000, isParent: true)
        let first = transaction("child-a", amount: -400, isChild: true, parentID: parent.id)
        let second = transaction("child-b", amount: -600, isChild: true, parentID: parent.id)

        let childOnly = try duplicatePlan([parent, first, second], selections: [first.id])
        #expect(childOnly.afterSnapshots.count == 3)
        #expect(childOnly.selections == [TransactionDuplicateSelectionResolution(
            selectedTransactionID: first.id,
            familyRootTransactionID: parent.id,
            duplicateGroupID: parent.id
        )])

        let overlapping = try duplicatePlan(
            [second, parent, first],
            selections: [parent.id, first.id, second.id, parent.id]
        )
        #expect(overlapping.afterSnapshots.count == 3)
        #expect(overlapping.groups.count == 1)
        #expect(overlapping.groups[0].selectedTransactionIDs == [parent.id, first.id, second.id])
        #expect(overlapping.selections.map(\.selectedTransactionID) == [parent.id, first.id, second.id])
        #expect(Set(overlapping.groups[0].duplicateTransactionIDs).count == 3)
    }

    @Test func transferDuplicateCreatesFreshReciprocalPairAndLeavesSourcesUntouched() throws {
        let source = transaction("source", account: "checking", amount: -2_500, transferID: "peer")
        let peer = transaction("peer", account: "savings", amount: 2_500, transferID: "source")
        let plan = try duplicatePlan([peer, source], selections: [source.id])
        let copies = Dictionary(uniqueKeysWithValues: plan.afterSnapshots.map { ($0.id, $0) })

        #expect(plan.beforeSnapshots == [peer, source])
        #expect(plan.afterSnapshots.count == 2)
        #expect(copies["copy-source"]?.transferID == "copy-peer")
        #expect(copies["copy-peer"]?.transferID == "copy-source")
        #expect(plan.afterSnapshots.allSatisfy { ![source.id, peer.id].contains($0.id) })
        #expect(plan.afterSnapshots.allSatisfy { $0.cleared == false && $0.reconciled == false })
    }

    @Test func splitFamilyWithTransferChildClonesFamilyAndPeerAsOneGraph() throws {
        let parent = transaction("parent", amount: -400, isParent: true)
        let transferChild = transaction(
            "child-transfer",
            account: "checking",
            amount: -400,
            isChild: true,
            parentID: parent.id,
            transferID: "transfer-peer"
        )
        let peer = transaction("transfer-peer", account: "savings", amount: 400, transferID: transferChild.id)
        let plan = try duplicatePlan([parent, transferChild, peer], selections: [parent.id])
        let copies = Dictionary(uniqueKeysWithValues: plan.afterSnapshots.map { ($0.id, $0) })

        #expect(plan.afterSnapshots.count == 3)
        #expect(plan.groups.count == 1)
        #expect(copies["copy-child-transfer"]?.parentID == "copy-parent")
        #expect(copies["copy-child-transfer"]?.transferID == "copy-transfer-peer")
        #expect(copies["copy-transfer-peer"]?.transferID == "copy-child-transfer")
        #expect(plan.selections[0].familyRootTransactionID == "parent")

        let overlapping = try duplicatePlan(
            [parent, transferChild, peer],
            selections: [parent.id, peer.id]
        )
        #expect(overlapping.groups.count == 1)
        #expect(overlapping.afterSnapshots.count == 3)
        #expect(overlapping.groups[0].selectedTransactionIDs == [parent.id, peer.id])
    }

    @Test func copiesImportedMetadataAndScheduleOnlyWhereSourceStoresThem() throws {
        let parent = transaction(
            "parent",
            amount: -500,
            isParent: true,
            scheduleID: "schedule-parent",
            importedID: "imported-parent",
            importedPayee: "Imported parent payee",
            importedDescription: "Imported description"
        )
        let child = transaction("child", amount: -500, isChild: true, parentID: parent.id)
        let plan = try duplicatePlan([parent, child], selections: [child.id])
        let copies = Dictionary(uniqueKeysWithValues: plan.afterSnapshots.map { ($0.id, $0) })

        #expect(copies["copy-parent"]?.scheduleID == "schedule-parent")
        #expect(copies["copy-parent"]?.importedID == "imported-parent")
        #expect(copies["copy-parent"]?.importedPayee == "Imported parent payee")
        #expect(copies["copy-parent"]?.importedDescription == "Imported description")
        #expect(copies["copy-child"]?.scheduleID == nil)
        #expect(copies["copy-child"]?.importedID == nil)
        #expect(copies["copy-child"]?.importedPayee == nil)
        #expect(copies["copy-child"]?.importedDescription == nil)
    }

    @Test func everyCloneResetsStatusesWithoutDroppingOtherPhysicalMetadata() throws {
        let parent = transaction(
            "parent",
            amount: -900,
            isParent: true,
            cleared: true,
            reconciled: true,
            startingBalance: true,
            scheduleID: "schedule",
            importedID: "financial-id",
            importedPayee: "source imported payee",
            importedDescription: "source imported description"
        )
        let child = transaction(
            "child",
            amount: -900,
            isChild: true,
            parentID: parent.id,
            cleared: true,
            reconciled: true,
            notes: "child note"
        )
        let plan = try duplicatePlan([parent, child], selections: [parent.id])

        #expect(plan.afterSnapshots.allSatisfy { $0.cleared == false && $0.reconciled == false })
        let copiedParent = try #require(plan.afterSnapshots.first { $0.id == "copy-parent" })
        let copiedChild = try #require(plan.afterSnapshots.first { $0.id == "copy-child" })
        #expect(copiedParent.startingBalance == parent.startingBalance)
        #expect(copiedParent.scheduleID == parent.scheduleID)
        #expect(copiedParent.importedID == parent.importedID)
        #expect(copiedParent.importedPayee == parent.importedPayee)
        #expect(copiedParent.importedDescription == parent.importedDescription)
        #expect(copiedChild.notes == child.notes)
        #expect(plan.requestsCategoryLearning == false)
    }

    @Test func allocationAndSnapshotOrderProduceCanonicalFreshPlan() throws {
        let parent = transaction("parent", amount: -1_000, isParent: true)
        let childA = transaction("child-a", amount: -400, isChild: true, parentID: parent.id)
        let childB = transaction("child-b", amount: -600, isChild: true, parentID: parent.id)
        let sources = [parent, childA, childB]
        let allocated = allocations(for: sources)
        let first = try TransactionDuplicatePlanner.plan(
            selections: ["child-b", "parent"],
            sourceSnapshots: sources,
            allocations: allocated
        )
        let reversed = try TransactionDuplicatePlanner.plan(
            selections: ["child-b", "parent"],
            sourceSnapshots: Array(sources.reversed()),
            allocations: Array(allocated.reversed())
        )

        #expect(first == reversed)
        #expect(first.fingerprintMaterial == reversed.fingerprintMaterial)
        #expect(first.allocations.map(\.sourceTransactionID) == ["child-a", "child-b", "parent"])
        #expect(first.afterSnapshots.map(\.sortOrder) == first.allocations.map(\.sortOrder))
        #expect(first.afterSnapshots.allSatisfy { $0.sortOrder?.isFinite == true })
        let sourceOrders = Dictionary(uniqueKeysWithValues: first.beforeSnapshots.map { ($0.id, $0.sortOrder) })
        #expect(first.allocations.allSatisfy { $0.sortOrder != sourceOrders[$0.sourceTransactionID] })
    }

    @Test func rejectsSplitErrorsZeroChildParentsAndMissingParents() {
        let splitErrorParent = transaction("parent", amount: -100, isParent: true, splitError: "{\"difference\":-100}")
        let child = transaction("child", amount: -100, isChild: true, parentID: "parent")
        expectFailure(.sourceSplitError("parent"), snapshots: [splitErrorParent, child], selections: ["parent"])

        let emptyParent = transaction("empty-parent", amount: -100, isParent: true)
        expectFailure(.zeroChildSplit("empty-parent"), snapshots: [emptyParent], selections: ["empty-parent"])

        let missingParentChild = transaction("orphan-child", amount: -100, isChild: true, parentID: "missing-parent")
        expectFailure(.malformedSplit("orphan-child"), snapshots: [missingParentChild], selections: ["orphan-child"])

        let conflicting = transaction("conflicting", amount: -100, isParent: true, isChild: true, parentID: "another")
        expectFailure(.malformedSplit("conflicting"), snapshots: [conflicting], selections: ["conflicting"])
    }

    @Test func rejectsOrphanNonreciprocalExtraAndSelfTransferLinks() {
        let orphan = transaction("orphan", account: "checking", amount: -100, transferID: "missing")
        expectFailure(.malformedTransfer("orphan"), snapshots: [orphan], selections: ["orphan"])

        let source = transaction("source", account: "checking", amount: -100, transferID: "peer")
        let peer = transaction("peer", account: "savings", amount: 100)
        expectFailure(.malformedTransfer("source"), snapshots: [source, peer], selections: ["source"])

        let reciprocalSource = transaction("source", account: "checking", amount: -100, transferID: "peer")
        let reciprocalPeer = transaction("peer", account: "savings", amount: 100, transferID: "source")
        let extraBacklink = transaction("extra", account: "credit", amount: 50, transferID: "source")
        expectFailure(
            .malformedTransfer("extra"),
            snapshots: [reciprocalSource, reciprocalPeer, extraBacklink],
            selections: ["extra"]
        )

        let selfTransfer = transaction("self", account: "checking", amount: 100, transferID: "self")
        expectFailure(.malformedTransfer("self"), snapshots: [selfTransfer], selections: ["self"])
    }

    @Test func rejectsBadRequiredFieldsAndUnselectedPhysicalRows() {
        let noAccount = transaction("no-account", account: "", amount: 1)
        expectFailure(.missingRequiredField("no-account"), snapshots: [noAccount], selections: ["no-account"])

        let invalidDate = transaction("invalid-date", amount: 1, dateValue: 20260230)
        expectFailure(.missingRequiredField("invalid-date"), snapshots: [invalidDate], selections: ["invalid-date"])

        let missingDate = transaction("missing-date", amount: 1, dateValue: nil)
        expectFailure(.missingRequiredField("missing-date"), snapshots: [missingDate], selections: ["missing-date"])

        let outOfRangeYear = transaction("year-10000", amount: 1, dateValue: 100_000_101)
        expectFailure(.missingRequiredField("year-10000"), snapshots: [outOfRangeYear], selections: ["year-10000"])

        let noAmount = transaction("no-amount", amount: nil)
        expectFailure(.missingRequiredField("no-amount"), snapshots: [noAmount], selections: ["no-amount"])

        let selected = transaction("selected", amount: 1)
        let extra = transaction("extra", account: "elsewhere", amount: 2)
        expectFailure(.unselectedSourceSnapshot("extra"), snapshots: [selected, extra], selections: ["selected"])
    }

    @Test func strictActualDateParserAcceptsMinimumYearAndProducesMonthID() throws {
        let minimumYear = transaction("year-0001", amount: 1, dateValue: 10_101)
        let plan = try duplicatePlan([minimumYear], selections: [minimumYear.id])
        #expect(plan.affectedResources.months == ["0001-01"])
    }

    @Test func rejectsSplitFamilyWhoseChildrenDoNotSumToParentWithoutStoredError() {
        let parent = transaction("parent", amount: -1_000, isParent: true)
        let first = transaction("child-a", amount: -400, isChild: true, parentID: parent.id)
        let second = transaction("child-b", amount: -500, isChild: true, parentID: parent.id)

        expectFailure(.malformedSplit(parent.id), snapshots: [parent, first, second], selections: [parent.id])
    }

    @Test func rejectsGeneratedIdentityAndOrderCollisionsOrNonfiniteValues() {
        let source = transaction("source", amount: 1)
        let peer = transaction("peer", account: "savings", amount: 2)
        let sources = [source, peer]

        expectFailure(
            .duplicateDuplicateID("copy"),
            snapshots: sources,
            selections: ["source", "peer"],
            allocations: [
                allocation("source", duplicateID: "copy", order: 1_000),
                allocation("peer", duplicateID: "copy", order: 1_001),
            ]
        )
        expectFailure(
            .duplicateIDAliasesSource("peer"),
            snapshots: sources,
            selections: ["source", "peer"],
            allocations: [
                allocation("source", duplicateID: "peer", order: 1_000),
                allocation("peer", duplicateID: "copy-peer", order: 1_001),
            ]
        )
        expectFailure(
            .invalidSortOrder("source"),
            snapshots: [source],
            selections: ["source"],
            allocations: [allocation("source", duplicateID: "copy-source", order: .nan)]
        )
        expectFailure(
            .invalidSortOrder("source"),
            snapshots: [source],
            selections: ["source"],
            allocations: [allocation("source", duplicateID: "copy-source", order: .infinity)]
        )
        let nonfiniteSource = transaction("nonfinite-source", amount: 1, sortOrder: .nan)
        expectFailure(
            .invalidSortOrder("nonfinite-source"),
            snapshots: [nonfiniteSource],
            selections: ["nonfinite-source"]
        )
        expectFailure(
            .staleSortOrder("source"),
            snapshots: [source],
            selections: ["source"],
            allocations: [allocation("source", duplicateID: "copy-source", order: source.sortOrder ?? 0)]
        )
        expectFailure(
            .duplicateAllocation("source"),
            snapshots: [source],
            selections: ["source"],
            allocations: [
                allocation("source", duplicateID: "copy-a", order: 1_000),
                allocation("source", duplicateID: "copy-b", order: 1_001),
            ]
        )
    }

    @Test func sourceSnapshotChangesChangeFingerprintMaterial() throws {
        let original = transaction("source", amount: -50, notes: "original")
        let changed = transaction("source", amount: -50, notes: "edited after review")
        let fixedAllocation = [allocation("source", duplicateID: "copy-source", order: 1_000)]
        let first = try TransactionDuplicatePlanner.plan(
            selections: ["source"],
            sourceSnapshots: [original],
            allocations: fixedAllocation
        )
        let second = try TransactionDuplicatePlanner.plan(
            selections: ["source"],
            sourceSnapshots: [changed],
            allocations: fixedAllocation
        )

        #expect(first.beforeSnapshots != second.beforeSnapshots)
        #expect(first.fingerprintMaterial != second.fingerprintMaterial)
        #expect(first.afterSnapshots.first?.notes == "original")
        #expect(second.afterSnapshots.first?.notes == "edited after review")
    }

    private func duplicatePlan(
        _ snapshots: [TransactionBatchTransactionSnapshot],
        selections: [String]
    ) throws -> TransactionDuplicatePlan {
        try TransactionDuplicatePlanner.plan(
            selections: selections,
            sourceSnapshots: snapshots,
            allocations: allocations(for: snapshots)
        )
    }

    private func allocations(for snapshots: [TransactionBatchTransactionSnapshot]) -> [TransactionDuplicateAllocation] {
        snapshots.sorted { $0.id < $1.id }.enumerated().map { index, snapshot in
            allocation(snapshot.id, duplicateID: "copy-\(snapshot.id)", order: Double(1_000 + index))
        }
    }

    private func allocation(_ sourceID: String, duplicateID: String, order: Double) -> TransactionDuplicateAllocation {
        TransactionDuplicateAllocation(
            sourceTransactionID: sourceID,
            duplicateTransactionID: duplicateID,
            sortOrder: order
        )
    }

    private func expectFailure(
        _ expected: TransactionDuplicatePlannerError,
        snapshots: [TransactionBatchTransactionSnapshot],
        selections: [String],
        allocations suppliedAllocations: [TransactionDuplicateAllocation]? = nil
    ) {
        do {
            _ = try TransactionDuplicatePlanner.plan(
                selections: selections,
                sourceSnapshots: snapshots,
                allocations: suppliedAllocations ?? allocations(for: snapshots)
            )
            Issue.record("Expected duplicate planner error: \(expected)")
        } catch let error as TransactionDuplicatePlannerError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected duplicate planner error \(expected), received \(error)")
        }
    }

    private func transaction(
        _ id: String,
        account: String = "checking",
        amount: Int? = -100,
        dateValue: Int? = 20260929,
        isParent: Bool? = false,
        isChild: Bool? = false,
        parentID: String? = nil,
        transferID: String? = nil,
        cleared: Bool? = true,
        reconciled: Bool? = true,
        sortOrder: Double? = 10,
        notes: String? = "memo",
        startingBalance: Bool? = true,
        splitError: String? = nil,
        scheduleID: String? = nil,
        importedID: String? = nil,
        importedPayee: String? = nil,
        importedDescription: String? = nil
    ) -> TransactionBatchTransactionSnapshot {
        TransactionBatchTransactionSnapshot(
            id: id,
            columns: physicalColumns,
            accountID: account,
            dateValue: dateValue,
            amount: amount,
            payeeID: "payee-\(id)",
            categoryID: "category-\(id)",
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            tombstone: false,
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

    private var physicalColumns: [String] {
        [
            "acct", "amount", "category", "cleared", "date", "description", "error",
            "financial_id", "id", "imported_description", "imported_payee", "isChild",
            "isParent", "notes", "parent_id", "reconciled", "schedule", "sort_order",
            "starting_balance_flag", "tombstone", "transferred_id",
        ].sorted()
    }
}
