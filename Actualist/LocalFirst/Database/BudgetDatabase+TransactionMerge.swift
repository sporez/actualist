import CryptoKit
import Foundation
import GRDB

private struct TransactionMergeDatabasePlan {
    let review: TransactionMergeReview
    let plan: TransactionMergePlan?
}

private struct TransactionMergeFingerprintAccount: Encodable {
    let id: String
    let isOffBudget: Bool
}

private struct TransactionMergeFingerprintPayeeDestination: Encodable {
    let payeeID: String
    let accountID: String
}

private struct TransactionMergeFingerprintPayload: Encodable {
    let orderedTransactionIDs: [String]
    let firstGraph: [TransactionBatchTransactionSnapshot]
    let secondGraph: [TransactionBatchTransactionSnapshot]
    let accounts: [TransactionMergeFingerprintAccount]
    let transferPayeeDestinations: [TransactionMergeFingerprintPayeeDestination]
}

extension BudgetDatabase {
    func reviewTransactionMerge(
        context: TransactionSelectionContext,
        orderedTransactionIDs: [String]
    ) throws -> TransactionMergeReview {
        let reviewID = UUID().uuidString
        return try queue.read { db in
            try transactionMergeDatabasePlan(
                id: reviewID,
                context: context,
                orderedTransactionIDs: orderedTransactionIDs,
                db: db
            ).review
        }
    }

    func commitTransactionMerge(
        review: TransactionMergeReview,
        authorization: TransactionMergeAuthorization?,
        now: Date = Date()
    ) throws -> TransactionMergeReceipt {
        try sessionWritesAllowed.withLock { allowed in
            guard allowed else { throw LocalFirstError.budgetNotOpened }
            try Task.checkCancellation()
            let committed = try commitLocalPlan(now: now) { db in
                try Task.checkCancellation()
                let current = try transactionMergeDatabasePlan(
                    id: review.id,
                    context: review.context,
                    orderedTransactionIDs: review.orderedTransactionIDs,
                    db: db
                )
                guard current.review == review,
                      review.canSubmit,
                      let plan = current.plan else {
                    throw LocalFirstError.invalidLocalWrite(
                        "the selected transactions changed; review the merge again"
                    )
                }
                guard authorization == transactionMergeAuthorization(for: current.review) else {
                    throw LocalFirstError.invalidLocalWrite(
                        "confirm the reconciled transaction warning again"
                    )
                }

                var builder = LocalFirstSyncMessageBuilder()
                let messages = try transactionMergeMessages(for: plan, db: db, builder: &builder)
                guard !messages.isEmpty else {
                    throw LocalFirstError.invalidLocalWrite("the merge has no transaction changes")
                }
                let affectedIDs = plan.beforeSnapshots.map(\.id)
                let descriptor = TransactionMergeActionDescriptor(
                    orderedInputTransactionIDs: plan.orderedTransactionIDs,
                    keptTransactionID: plan.keptTransactionID,
                    droppedTransactionID: plan.droppedTransactionID,
                    affectedGraphTransactionIDs: affectedIDs
                )
                let receipt = TransactionMergeReceipt(
                    changedAccountIDs: plan.affectedResources.changed.accounts,
                    changedMonths: plan.affectedResources.changed.months,
                    changedTransactionIDs: affectedIDs,
                    actionID: review.id
                )
                return LocalCommitPlan(
                    drafts: messages,
                    action: ActionLogCommit(
                        descriptor: .transactionMerge(descriptor),
                        source: .ui,
                        actionID: review.id,
                        learningTransactionIDs: []
                    ),
                    outcome: receipt
                )
            }
            return committed.outcome
        }
    }

    private func transactionMergeDatabasePlan(
        id: String,
        context: TransactionSelectionContext,
        orderedTransactionIDs: [String],
        db: Database
    ) throws -> TransactionMergeDatabasePlan {
        guard orderedTransactionIDs.count == 2,
              orderedTransactionIDs.allSatisfy({ !$0.isEmpty }),
              Set(orderedTransactionIDs).count == 2 else {
            throw LocalFirstError.invalidLocalWrite("select two different transactions to merge")
        }

        let columns = try resolveTransactionRowColumns(db: db)
        let firstGraph = try transactionMergeGraph(
            containing: orderedTransactionIDs[0],
            columns: columns,
            db: db
        )
        let secondGraph = try transactionMergeGraph(
            containing: orderedTransactionIDs[1],
            columns: columns,
            db: db
        )
        let firstSnapshots = firstGraph.values.sorted { $0.id < $1.id }
        let secondSnapshots = secondGraph.values.sorted { $0.id < $1.id }
        let allSnapshotsByID = Dictionary(
            (firstSnapshots + secondSnapshots).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let reference = try transactionMergeReferenceMetadata(
            snapshots: Array(allSnapshotsByID.values),
            db: db
        )
        let input = TransactionMergePlannerInput(
            orderedTransactionIDs: orderedTransactionIDs,
            firstGraph: firstSnapshots,
            secondGraph: secondSnapshots,
            referenceMetadata: reference
        )
        let fingerprint = try transactionMergeFingerprint(input)
        let result = TransactionMergePlanner.plan(input)
        let plan = result.plan
        let reconciledIDs = plan?.reconciledTransactionIDs
            ?? allSnapshotsByID.values.filter { $0.reconciled == true }.map(\.id).sorted()
        let affectedResources = plan?.affectedResources
            ?? transactionMergeAffectedResources(Array(allSnapshotsByID.values))
        let keptRow = plan.flatMap { plan in
            plan.afterSnapshots.first { $0.id == plan.keptTransactionID }
        }.flatMap(transactionMergeReviewRow)
        let droppedRow = plan.flatMap { plan in
            plan.beforeSnapshots.first { $0.id == plan.droppedTransactionID }
        }.flatMap(transactionMergeReviewRow)
        return TransactionMergeDatabasePlan(
            review: TransactionMergeReview(
                id: id,
                context: context,
                orderedTransactionIDs: orderedTransactionIDs,
                keptRow: keptRow,
                droppedRow: droppedRow,
                fieldEffects: plan?.fieldEffects ?? [],
                childMovements: plan?.childMovements ?? [],
                transferDisposition: plan?.transferDisposition ?? .none,
                reciprocalTransferPairs: plan?.reciprocalTransferPairs ?? [],
                tombstonedTransactionIDs: plan?.tombstonedTransactionIDs ?? [],
                tombstonedPeerIDs: plan?.tombstonedPeerIDs ?? [],
                affectedResources: affectedResources,
                blockedReason: result.blockedReason,
                reconciledTransactionIDs: reconciledIDs,
                reviewFingerprint: fingerprint
            ),
            plan: plan
        )
    }

    private func transactionMergeGraph(
        containing transactionID: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> [String: TransactionBatchTransactionSnapshot] {
        let graph = try transactionBatchGraph(containing: transactionID, columns: columns, db: db)
        guard graph.invalidReason == nil,
              graph.snapshots[transactionID] != nil,
              graph.snapshots.values.allSatisfy(TransactionCommandActionValidation.isCompleteSnapshot) else {
            throw LocalFirstError.invalidLocalWrite(
                graph.invalidReason ?? "the selected transaction graph is incomplete"
            )
        }
        return graph.snapshots
    }

    private func transactionMergeReferenceMetadata(
        snapshots: [TransactionBatchTransactionSnapshot],
        db: Database
    ) throws -> TransactionMergeReferenceMetadata {
        var destinations: [TransactionMergePayeeDestination] = []
        for payeeID in Set(snapshots.compactMap(\.payeeID)).sorted() {
            if let accountID = try transferAccountID(ifPayee: payeeID, db: db) {
                destinations.append(TransactionMergePayeeDestination(
                    payeeID: payeeID,
                    accountID: accountID
                ))
            }
        }

        var accountIDs = Set(snapshots.compactMap(\.accountID))
        accountIDs.formUnion(destinations.map(\.accountID))
        guard try tableExists("accounts", db: db),
              try columnSet(for: "accounts", db: db).contains("id") else {
            return TransactionMergeReferenceMetadata(accounts: [], transferPayeeDestinations: destinations)
        }
        var accounts: [TransactionMergeAccountMetadata] = []
        for accountID in accountIDs.sorted() where try rowExists(
            table: "accounts",
            rowID: accountID,
            db: db
        ) {
            accounts.append(TransactionMergeAccountMetadata(
                id: accountID,
                isOffBudget: try accountOffBudget(accountID, db: db)
            ))
        }
        return TransactionMergeReferenceMetadata(
            accounts: accounts,
            transferPayeeDestinations: destinations.sorted {
                ($0.payeeID, $0.accountID) < ($1.payeeID, $1.accountID)
            }
        )
    }

    private func transactionMergeFingerprint(_ input: TransactionMergePlannerInput) throws -> String {
        let payload = TransactionMergeFingerprintPayload(
            orderedTransactionIDs: input.orderedTransactionIDs,
            firstGraph: input.firstGraph.sorted { $0.id < $1.id },
            secondGraph: input.secondGraph.sorted { $0.id < $1.id },
            accounts: input.referenceMetadata.accounts.sorted { $0.id < $1.id }.map {
                TransactionMergeFingerprintAccount(id: $0.id, isOffBudget: $0.isOffBudget)
            },
            transferPayeeDestinations: input.referenceMetadata.transferPayeeDestinations.sorted {
                ($0.payeeID, $0.accountID) < ($1.payeeID, $1.accountID)
            }.map {
                TransactionMergeFingerprintPayeeDestination(payeeID: $0.payeeID, accountID: $0.accountID)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func transactionMergeAuthorization(
        for review: TransactionMergeReview
    ) -> TransactionMergeAuthorization? {
        guard !review.reconciledTransactionIDs.isEmpty else { return nil }
        return TransactionMergeAuthorization(
            reviewID: review.id,
            reviewFingerprint: review.reviewFingerprint,
            reconciledTransactionIDs: review.reconciledTransactionIDs
        )
    }

    private func transactionMergeMessages(
        for plan: TransactionMergePlan,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard plan.beforeSnapshots.map(\.id) == plan.afterSnapshots.map(\.id),
              plan.beforeSnapshots.count == plan.afterSnapshots.count else {
            throw LocalFirstError.invalidLocalWrite("the transaction merge plan has incomplete snapshots")
        }
        let columns = try resolveTransactionRowColumns(db: db)
        var messages: [ActualSyncDecodedMessage] = []
        for (before, after) in zip(plan.beforeSnapshots, plan.afterSnapshots) {
            guard before.columns == after.columns,
                  TransactionCommandActionValidation.isCompleteSnapshot(before),
                  TransactionCommandActionValidation.isCompleteSnapshot(after) else {
                throw LocalFirstError.invalidLocalWrite("the transaction merge schema changed")
            }
            try transactionMergeRowMessages(
                from: before,
                to: after,
                columns: columns,
                builder: &builder,
                messages: &messages
            )
        }
        return messages
    }

    private func transactionMergeRowMessages(
        from before: TransactionBatchTransactionSnapshot,
        to after: TransactionBatchTransactionSnapshot,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder,
        messages: inout [ActualSyncDecodedMessage]
    ) throws {
        func text(_ column: String, _ old: String?, _ new: String?) throws {
            try appendTransactionMergeDifference(
                rowID: before.id,
                column: column,
                beforeColumns: before.columns,
                availableColumns: columns.all,
                before: old,
                after: new,
                builder: &builder,
                messages: &messages
            ) { $0.map(LocalFirstSyncValue.string) ?? .null }
        }
        func integer(_ column: String, _ old: Int?, _ new: Int?) throws {
            try appendTransactionMergeDifference(
                rowID: before.id,
                column: column,
                beforeColumns: before.columns,
                availableColumns: columns.all,
                before: old,
                after: new,
                builder: &builder,
                messages: &messages
            ) { $0.map { .int(Int64($0)) } ?? .null }
        }
        func flag(_ column: String, _ old: Bool?, _ new: Bool?) throws {
            try appendTransactionMergeDifference(
                rowID: before.id,
                column: column,
                beforeColumns: before.columns,
                availableColumns: columns.all,
                before: old,
                after: new,
                builder: &builder,
                messages: &messages
            ) { $0.map(LocalFirstSyncValue.bool) ?? .null }
        }
        func decimal(_ column: String, _ old: Double?, _ new: Double?) throws {
            try appendTransactionMergeDifference(
                rowID: before.id,
                column: column,
                beforeColumns: before.columns,
                availableColumns: columns.all,
                before: old,
                after: new,
                builder: &builder,
                messages: &messages
            ) { $0.map(LocalFirstSyncValue.double) ?? .null }
        }

        try text(columns.account, before.accountID, after.accountID)
        try integer("date", before.dateValue, after.dateValue)
        try integer("amount", before.amount, after.amount)
        try text(columns.payee, before.payeeID, after.payeeID)
        try text("category", before.categoryID, after.categoryID)
        try text("notes", before.notes, after.notes)
        try flag("cleared", before.cleared, after.cleared)
        try flag("reconciled", before.reconciled, after.reconciled)
        try flag("tombstone", before.tombstone, after.tombstone)
        if let isParent = columns.isParent {
            try flag(isParent, before.isParent, after.isParent)
        }
        if let isChild = columns.isChild {
            try flag(isChild, before.isChild, after.isChild)
        }
        try text("parent_id", before.parentID, after.parentID)
        if let transferID = columns.transferID {
            try text(transferID, before.transferID, after.transferID)
        }
        if let sortOrder = columns.sortOrder {
            try decimal(sortOrder, before.sortOrder, after.sortOrder)
        }
        try text("error", before.splitError, after.splitError)
        try flag("starting_balance_flag", before.startingBalance, after.startingBalance)
        try text("schedule", before.scheduleID, after.scheduleID)
        try text("financial_id", before.importedID, after.importedID)
        try text("imported_payee", before.importedPayee, after.importedPayee)
        try text("imported_description", before.importedDescription, after.importedDescription)
    }

    private func appendTransactionMergeDifference<Value: Equatable>(
        rowID: String,
        column: String,
        beforeColumns: [String],
        availableColumns: Set<String>,
        before: Value?,
        after: Value?,
        builder: inout LocalFirstSyncMessageBuilder,
        messages: inout [ActualSyncDecodedMessage],
        value: (Value?) -> LocalFirstSyncValue
    ) throws {
        guard before != after else { return }
        guard beforeColumns.contains(column), availableColumns.contains(column) else {
            throw LocalFirstError.invalidLocalWrite("the transaction merge field is unavailable: \(column)")
        }
        messages.append(try builder.makeMessage(
            dataset: "transactions",
            row: rowID,
            column: column,
            value: value(after)
        ))
    }

    private func transactionMergeReviewRow(
        _ snapshot: TransactionBatchTransactionSnapshot
    ) -> TransactionMergeReviewRow? {
        guard let accountID = snapshot.accountID,
              let dateValue = snapshot.dateValue,
              let amount = snapshot.amount else { return nil }
        return TransactionMergeReviewRow(
            transactionID: snapshot.id,
            accountID: accountID,
            date: String(format: "%04d-%02d-%02d", dateValue / 10_000, (dateValue / 100) % 100, dateValue % 100),
            amountMinorUnits: amount,
            payeeID: snapshot.payeeID,
            categoryID: snapshot.categoryID,
            notes: snapshot.notes,
            cleared: snapshot.cleared,
            reconciled: snapshot.reconciled,
            isParent: snapshot.isParent == true,
            isChild: snapshot.isChild == true,
            isTransfer: snapshot.transferID != nil
        )
    }

    private func transactionMergeAffectedResources(
        _ snapshots: [TransactionBatchTransactionSnapshot]
    ) -> TransactionMergeAffectedResources {
        let months = Set(snapshots.compactMap { snapshot -> String? in
            guard let value = snapshot.dateValue, value > 0 else { return nil }
            let digits = String(format: "%08d", value)
            guard digits.count == 8 else { return nil }
            return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))"
        })
        return TransactionMergeAffectedResources(
            changed: ChangedResources(
                accounts: Array(Set(snapshots.compactMap(\.accountID))).sorted(),
                months: months.sorted(),
                transactions: snapshots.map(\.id).sorted()
            ),
            payeeIDs: Array(Set(snapshots.compactMap(\.payeeID))).sorted(),
            categoryIDs: Array(Set(snapshots.compactMap(\.categoryID))).sorted()
        )
    }
}
