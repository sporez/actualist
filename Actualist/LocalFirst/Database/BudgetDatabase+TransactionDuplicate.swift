import CryptoKit
import Foundation
import GRDB

extension BudgetDatabase {
    private struct DuplicateDatabasePlan {
        let review: TransactionDuplicateReview
        let sourcePlan: TransactionDuplicatePlan
        let columns: TransactionRowColumns
        let descriptor: TransactionDuplicateActionDescriptor
    }

    func reviewTransactionDuplicate(
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity],
        cloneIDAtIndex: @escaping @Sendable (Int) -> String = { _ in UUID().uuidString },
        now: Date = Date()
    ) throws -> TransactionDuplicateReview {
        let id = UUID().uuidString
        return try queue.read { db in
            try transactionDuplicatePlan(
                id: id,
                context: context,
                selections: selections,
                allocations: nil,
                cloneIDAtIndex: cloneIDAtIndex,
                now: now,
                db: db
            ).review
        }
    }

    func commitTransactionDuplicate(
        review: TransactionDuplicateReview,
        now: Date = Date()
    ) throws -> TransactionDuplicateReceipt {
        try Task.checkCancellation()
        try Task.checkCancellation()
        let committed = try commitLocalPlan(now: now) { db in
            try Task.checkCancellation()
            let plan = try transactionDuplicatePlan(
                id: review.id,
                context: review.context,
                selections: review.selections,
                allocations: review.allocations,
                cloneIDAtIndex: nil,
                now: now,
                db: db
            )
            guard review.canSubmit,
                  Self.duplicateAllocationsExactlyMatch(plan.review.allocations, review.allocations),
                  plan.review.reviewFingerprint == review.reviewFingerprint,
                  plan.review.groups == review.groups,
                  plan.review.affectedResources == review.affectedResources else {
                throw LocalFirstError.invalidLocalWrite(
                    "the selected transactions changed; review the duplicate again"
                )
            }
            let drafts = try transactionDuplicateDrafts(
                from: plan.sourcePlan,
                columns: plan.columns
            )
            guard !drafts.isEmpty else {
                throw LocalFirstError.invalidLocalWrite("the transaction duplicate has no writable rows")
            }
            let receipt = TransactionDuplicateReceipt(
                changed: plan.review.affectedResources,
                actionID: review.id
            )
            let action = ActionLogCommit(
                descriptor: .transactionDuplicate(plan.descriptor),
                source: .ui,
                actionID: review.id
            )
            return LocalCommitPlan(drafts: drafts, action: action, outcome: receipt)
        }
        return committed.outcome
    }

    private func transactionDuplicatePlan(
        id: String,
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity],
        allocations suppliedAllocations: [TransactionDuplicateAllocation]?,
        cloneIDAtIndex: (@Sendable (Int) -> String)?,
        now: Date,
        db: Database
    ) throws -> DuplicateDatabasePlan {
        guard !id.isEmpty,
              !selections.isEmpty,
              selections.allSatisfy({ !$0.transactionID.isEmpty && !$0.familyRootID.isEmpty }),
              Set(selections.map(\.transactionID)).count == selections.count else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction duplicate selection")
        }

        let columns = try resolveTransactionRowColumns(db: db)
        guard columns.hasTombstone,
              columns.hasParentID,
              columns.isParent != nil,
              columns.isChild != nil,
              columns.transferID != nil,
              columns.hasError,
              columns.hasCleared,
              columns.hasReconciled,
              columns.sortOrder != nil else {
            throw LocalFirstError.invalidLocalWrite("the transaction graph schema is incomplete")
        }

        let sourceSnapshots = try transactionDuplicateSourceSnapshots(
            selections: selections,
            columns: columns,
            db: db
        )
        let allocations: [TransactionDuplicateAllocation]
        if let suppliedAllocations {
            allocations = suppliedAllocations
        } else {
            guard let cloneIDAtIndex else {
                throw LocalFirstError.invalidLocalWrite("transaction duplicate IDs were not allocated")
            }
            let sortOrderBase = now.timeIntervalSince1970 * 1_000
            allocations = sourceSnapshots.enumerated().map { index, snapshot in
                TransactionDuplicateAllocation(
                    sourceTransactionID: snapshot.id,
                    duplicateTransactionID: cloneIDAtIndex(index),
                    sortOrder: sortOrderBase + Double(index)
                )
            }
        }
        try validateDuplicateCloneIDAvailability(
            allocations,
            sourceSnapshots: sourceSnapshots,
            columns: columns,
            db: db
        )

        let duplicatePlan: TransactionDuplicatePlan
        do {
            duplicatePlan = try TransactionDuplicatePlanner.plan(
                selections: selections.map(\.transactionID),
                sourceSnapshots: sourceSnapshots,
                allocations: allocations
            )
        } catch is TransactionDuplicatePlannerError {
            throw LocalFirstError.invalidLocalWrite("the selected transaction graph cannot be duplicated")
        }

        let groups = try transactionDuplicateReviewGroups(duplicatePlan)
        let fingerprint = try transactionDuplicateFingerprint(
            id: id,
            context: context,
            selections: selections,
            material: duplicatePlan.fingerprintMaterial
        )
        let review = TransactionDuplicateReview(
            id: id,
            context: context,
            selections: selections,
            groups: groups,
            allocations: duplicatePlan.allocations,
            affectedResources: duplicatePlan.affectedResources,
            reviewFingerprint: fingerprint,
            canSubmit: true
        )

        let descriptor = TransactionDuplicateActionDescriptor(
            selectedSourceTransactionIDs: selections.map(\.transactionID),
            preallocatedCloneTransactionIDs: duplicatePlan.allocations
                .map(\.duplicateTransactionID)
                .sorted()
        )
        return DuplicateDatabasePlan(
            review: review,
            sourcePlan: duplicatePlan,
            columns: columns,
            descriptor: descriptor
        )
    }

    private func transactionDuplicateDrafts(
        from plan: TransactionDuplicatePlan,
        columns: TransactionRowColumns
    ) throws -> [ActualSyncDecodedMessage] {
        var builder = LocalFirstSyncMessageBuilder()
        var drafts: [ActualSyncDecodedMessage] = []
        for snapshot in plan.afterSnapshots {
            drafts += try transactionBatchRestoreMessages(
                snapshot,
                columns: columns,
                builder: &builder
            )
        }
        return drafts
    }

    private func transactionDuplicateSourceSnapshots(
        selections: [TransactionSelectionIdentity],
        columns: TransactionRowColumns,
        db: Database
    ) throws -> [TransactionBatchTransactionSnapshot] {
        var snapshotsByID: [String: TransactionBatchTransactionSnapshot] = [:]
        for selection in selections {
            let graph = try transactionBatchGraph(
                containing: selection.transactionID,
                columns: columns,
                db: db
            )
            guard graph.invalidReason == nil,
                  let selected = graph.snapshots[selection.transactionID],
                  graph.snapshots.values.allSatisfy({
                      $0.tombstone == false
                          && TransactionCommandActionValidation.isCompleteSnapshot($0)
                  }) else {
                throw LocalFirstError.invalidLocalWrite("a transaction duplicate source graph is incomplete")
            }
            let isChild = selected.isChild == true
            guard (selection.role == .child) == isChild,
                  selection.role == .root || selected.parentID == selection.familyRootID,
                  selection.role == .child || selection.familyRootID == selection.transactionID else {
                throw LocalFirstError.invalidLocalWrite("the selected transaction family changed")
            }
            for snapshot in graph.snapshots.values {
                if let existing = snapshotsByID[snapshot.id], !existing.matches(snapshot) {
                    throw LocalFirstError.invalidLocalWrite("overlapping transaction duplicate sources changed")
                }
                snapshotsByID[snapshot.id] = snapshot
            }
        }

        let snapshots = snapshotsByID.values.sorted { $0.id < $1.id }
        guard !snapshots.isEmpty,
              try transactionBatchGraphMembershipMatches(snapshots, db: db) else {
            throw LocalFirstError.invalidLocalWrite("a transaction duplicate source graph is incomplete")
        }
        return snapshots
    }

    private func validateDuplicateCloneIDAvailability(
        _ allocations: [TransactionDuplicateAllocation],
        sourceSnapshots: [TransactionBatchTransactionSnapshot],
        columns: TransactionRowColumns,
        db: Database
    ) throws {
        let cloneIDs = allocations.map(\.duplicateTransactionID)
        let sourceIDs = Set(sourceSnapshots.map(\.id))
        guard !cloneIDs.isEmpty,
              cloneIDs.allSatisfy({ !$0.isEmpty }),
              Set(cloneIDs).count == cloneIDs.count,
              Set(cloneIDs).isDisjoint(with: sourceIDs) else {
            throw LocalFirstError.invalidLocalWrite("invalid or colliding transaction duplicate IDs")
        }
        for cloneID in cloneIDs {
            guard try transactionBatchSnapshot(id: cloneID, columns: columns, db: db) == nil else {
                throw LocalFirstError.invalidLocalWrite("a transaction duplicate ID already exists")
            }
        }
    }

    private func transactionDuplicateReviewGroups(
        _ plan: TransactionDuplicatePlan
    ) throws -> [TransactionDuplicateGroupReview] {
        let changesBySourceID = Dictionary(
            uniqueKeysWithValues: plan.rowChanges.map { ($0.before.id, $0) }
        )
        let allocationsBySourceID = Dictionary(
            uniqueKeysWithValues: plan.allocations.map { ($0.sourceTransactionID, $0) }
        )
        return try plan.groups.map { group in
            let rows = try group.sourceTransactionIDs.map { sourceID -> TransactionDuplicateReviewRow in
                guard let change = changesBySourceID[sourceID],
                      let allocation = allocationsBySourceID[sourceID],
                      allocation.duplicateTransactionID == change.duplicate.id,
                      let accountID = change.duplicate.accountID,
                      !accountID.isEmpty,
                      let dateValue = change.duplicate.dateValue,
                      let amount = change.duplicate.amount else {
                    throw LocalFirstError.invalidLocalWrite("the transaction duplicate review is incomplete")
                }
                return TransactionDuplicateReviewRow(
                    sourceTransactionID: sourceID,
                    duplicateTransactionID: allocation.duplicateTransactionID,
                    accountID: accountID,
                    date: Self.isoDateString(fromPacked: dateValue),
                    amountMinorUnits: amount,
                    payeeID: change.duplicate.payeeID,
                    categoryID: change.duplicate.categoryID,
                    isParent: change.duplicate.isParent == true,
                    isChild: change.duplicate.isChild == true,
                    parentDuplicateTransactionID: change.duplicate.parentID,
                    transferDuplicateTransactionID: change.duplicate.transferID
                )
            }
            return TransactionDuplicateGroupReview(
                id: group.id,
                selectedTransactionIDs: group.selectedTransactionIDs,
                sourceTransactionIDs: group.sourceTransactionIDs,
                duplicateTransactionIDs: group.duplicateTransactionIDs,
                rows: rows
            )
        }
    }

    private func transactionDuplicateFingerprint(
        id: String,
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity],
        material: TransactionDuplicateFingerprintMaterial
    ) throws -> String {
        let scope: String = switch context.scope {
        case .account(let accountID): "account:\(accountID)"
        case .spending: "spending"
        }
        let selected = selections.map { selection in
            TransactionDuplicateFingerprintSelection(
                transactionID: selection.transactionID,
                familyRootID: selection.familyRootID,
                role: selection.role == .child ? "child" : "root"
            )
        }
        let fingerprintInput = TransactionDuplicateFingerprintInput(
            reviewID: id,
            budgetID: context.budgetID,
            sessionGeneration: context.sessionGeneration,
            scope: scope,
            querySignature: context.querySignature.stableSortKey,
            selections: selected,
            material: material
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fingerprintInput)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func duplicateAllocationsExactlyMatch(
        _ lhs: [TransactionDuplicateAllocation],
        _ rhs: [TransactionDuplicateAllocation]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
            pair.0.sourceTransactionID == pair.1.sourceTransactionID
                && pair.0.duplicateTransactionID == pair.1.duplicateTransactionID
                && pair.0.sortOrder.bitPattern == pair.1.sortOrder.bitPattern
        }
    }
}

private struct TransactionDuplicateFingerprintSelection: Codable {
    let transactionID: String
    let familyRootID: String
    let role: String
}

private struct TransactionDuplicateFingerprintInput: Codable {
    let reviewID: String
    let budgetID: String
    let sessionGeneration: Int
    let scope: String
    let querySignature: String
    let selections: [TransactionDuplicateFingerprintSelection]
    let material: TransactionDuplicateFingerprintMaterial
}
