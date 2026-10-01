import CryptoKit
import Foundation
import GRDB

extension BudgetDatabase {
    private struct BatchPlan {
        let review: TransactionBatchReview
        let messages: [ActualSyncDecodedMessage]
        let descriptor: TransactionBatchActionDescriptor
        let affectedAccountIDs: [String]
        let affectedMonthIDs: [String]
        let affectedTransactionIDs: [String]
        let learningTransactionIDs: Set<String>
    }

    func reviewTransactionBatch(
        context: TransactionSelectionContext,
        intent: TransactionBatchIntent,
        selections: [TransactionSelectionIdentity],
        loadedUngroupedTransactionIDs: [String]
    ) throws -> TransactionBatchReview {
        let reviewID = UUID().uuidString
        return try queue.read { db in
            try transactionBatchPlan(
                id: reviewID,
                context: context,
                intent: intent,
                selections: selections,
                loadedUngroupedTransactionIDs: loadedUngroupedTransactionIDs,
                db: db
            ).review
        }
    }

    func commitTransactionBatch(
        review: TransactionBatchReview,
        authorization: TransactionBatchAuthorization?,
        now: Date = Date()
    ) throws -> TransactionBatchResult {
        try sessionWritesAllowed.withLock { allowed in
            guard allowed else { throw LocalFirstError.budgetNotOpened }
            try Task.checkCancellation()
            let committed = try commitLocalPlan(now: now) { db in
                try Task.checkCancellation()
                let plan = try transactionBatchPlan(
                    id: review.id,
                    context: review.context,
                    intent: review.intent,
                    selections: review.selections,
                    loadedUngroupedTransactionIDs: review.loadedUngroupedTransactionIDs,
                    db: db
                )
                guard plan.review.reviewFingerprint == review.reviewFingerprint,
                      plan.review.selections == review.selections,
                      plan.review.dispositions == review.dispositions,
                      plan.review.rowChanges == review.rowChanges,
                      plan.review.metadata == review.metadata,
                      plan.review.clearTarget == review.clearTarget,
                      plan.review.canSubmit,
                      plan.review.blockedCount == 0 else {
                    throw LocalFirstError.invalidLocalWrite("the selected transactions changed; review the batch again")
                }
                guard authorization == plan.review.authorization else {
                    throw LocalFirstError.invalidLocalWrite("confirm the reconciled transaction warning again")
                }
                let action = ActionLogCommit(
                    descriptor: .transactionBatch(plan.descriptor),
                    source: .ui,
                    actionID: review.id,
                    learningTransactionIDs: plan.learningTransactionIDs
                )
                return LocalCommitPlan(
                    drafts: plan.messages,
                    action: action,
                    outcome: TransactionBatchResult(
                        changedAccountIDs: plan.affectedAccountIDs,
                        changedMonthIDs: plan.affectedMonthIDs,
                        changedTransactionIDs: plan.affectedTransactionIDs,
                        actionID: review.id
                    )
                )
            }
            return committed.outcome
        }
    }

    private func transactionBatchPlan(
        id: String,
        context: TransactionSelectionContext,
        intent: TransactionBatchIntent,
        selections: [TransactionSelectionIdentity],
        loadedUngroupedTransactionIDs: [String],
        db: Database
    ) throws -> BatchPlan {
        guard !selections.isEmpty,
              Set(selections.map(\.transactionID)).count == selections.count,
              selections.allSatisfy({ !$0.transactionID.isEmpty && !$0.familyRootID.isEmpty }),
              Set(loadedUngroupedTransactionIDs).count == loadedUngroupedTransactionIDs.count,
              loadedUngroupedTransactionIDs.allSatisfy({ !$0.isEmpty }) else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction selection")
        }
        let columns = try resolveTransactionRowColumns(db: db)
        let isDelete = intent == .delete
        if isDelete && !columns.hasTombstone {
            throw LocalFirstError.invalidLocalWrite("transactions.tombstone is unavailable")
        }
        if case .clear = intent, !columns.hasCleared {
            throw LocalFirstError.invalidLocalWrite("transactions.cleared is unavailable")
        }
        let categoryID: String?
        if case .categorize(let requestedCategoryID) = intent {
            categoryID = requestedCategoryID
            if let categoryID,
               try !transactionBatchLiveCategoryExists(id: categoryID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
        } else {
            categoryID = nil
        }

        var graphs: [String: TransactionBatchGraphSnapshot] = [:]
        var loadedSnapshots: [String: TransactionBatchTransactionSnapshot] = [:]
        var graphSnapshots: [String: TransactionBatchTransactionSnapshot] = [:]
        var blockedReasons: [String: String] = [:]
        var feedRowsComplete = true
        for transactionID in loadedUngroupedTransactionIDs {
            guard let snapshot = try transactionBatchSnapshot(id: transactionID, columns: columns, db: db) else {
                feedRowsComplete = false
                continue
            }
            loadedSnapshots[transactionID] = snapshot
        }
        for selection in selections {
            let graph = try transactionBatchGraph(
                containing: selection.transactionID,
                columns: columns,
                db: db
            )
            graphs[selection.transactionID] = graph
            loadedSnapshots.merge(graph.snapshots, uniquingKeysWith: { _, incoming in incoming })
            graphSnapshots.merge(graph.snapshots, uniquingKeysWith: { _, incoming in incoming })
            if let reason = graph.invalidReason {
                blockedReasons[selection.transactionID] = reason
                continue
            }
            guard let row = graph.snapshots[selection.transactionID],
                  row.accountID != nil,
                  row.accountID?.isEmpty == false,
                  row.dateValue != nil,
                  row.amount != nil,
                  (selection.role == .child) == (row.isChild == true),
                  selection.role == .root || row.parentID == selection.familyRootID,
                  selection.role == .child || selection.familyRootID == selection.transactionID else {
                blockedReasons[selection.transactionID] = "The selected transaction no longer has the reviewed family identity."
                continue
            }
        }

        let loadedRows = loadedSnapshots.values.sorted { $0.id < $1.id }
        let targetClear: Bool?
        if case .clear = intent {
            let displayRows = loadedUngroupedTransactionIDs.compactMap { loadedSnapshots[$0] }
                .map(Self.displayBatchSnapshot)
            if !feedRowsComplete { targetClear = nil }
            else {
                targetClear = TransactionBatchClearTarget.fromLoadedRows(displayRows)
            }
        } else {
            targetClear = nil
        }

        var dispositions: [TransactionBatchDisposition] = []
        var messages: [ActualSyncDecodedMessage] = []
        var affectedIDs = Set<String>()
        var accountIDs = Set<String>()
        var monthIDs = Set<String>()
        var requiredTargetReconciled = Set<String>()
        var requiredPairedReconciled = Set<String>()
        var learningIDs = Set<String>()
        var handledForDelete = Set<String>()
        var builder = LocalFirstSyncMessageBuilder()

        for selection in selections {
            if let reason = blockedReasons[selection.transactionID] {
                dispositions.append(.blocked(TransactionBatchDispositionReason(
                    selection: selection,
                    explanation: reason
                )))
                continue
            }
            guard let graph = graphs[selection.transactionID],
                  let row = graph.snapshots[selection.transactionID] else {
                dispositions.append(.blocked(TransactionBatchDispositionReason(
                    selection: selection,
                    explanation: "The selected transaction is missing."
                )))
                continue
            }

            let messageStartIndex = messages.count
            var reconciledRequirement: (target: [String], paired: [String])?
            if case .clear = intent {
                guard let targetClear else {
                    dispositions.append(.blocked(TransactionBatchDispositionReason(
                        selection: selection,
                        explanation: "The loaded transaction graph has no reliable cleared state."
                    )))
                    continue
                }
                if row.reconciled == true {
                    dispositions.append(.skipped(TransactionBatchDispositionReason(
                        selection: selection,
                        explanation: "Reconciled transactions are left unchanged."
                    )))
                    continue
                }
                if row.cleared != targetClear {
                    messages.append(try builder.makeMessage(
                        dataset: "transactions",
                        row: selection.transactionID,
                        column: "cleared",
                        value: .bool(targetClear)
                    ))
                    affectedIDs.insert(selection.transactionID)
                }
                accountIDs.insert(row.accountID ?? "")
                if let month = Self.monthID(row.dateValue) { monthIDs.insert(month) }
            } else {
                let reconciled = try aggregateBatchReconciledRows(
                    transactionID: selection.transactionID,
                    columns: columns,
                    db: db
                )
                if !reconciled.target.isEmpty || !reconciled.paired.isEmpty {
                    requiredTargetReconciled.formUnion(reconciled.target)
                    requiredPairedReconciled.formUnion(reconciled.paired)
                    reconciledRequirement = (reconciled.target.sorted(), reconciled.paired.sorted())
                }

                switch intent {
                case .clear:
                    break
                case .categorize:
                    do {
                        try validateCategorizationTarget(
                            transactionID: selection.transactionID,
                            columns: columns.all,
                            payeeColumn: columns.payee,
                            db: db
                        )
                    } catch LocalFirstError.unsupportedSplitWrite {
                        dispositions.append(.blocked(TransactionBatchDispositionReason(
                            selection: selection,
                            explanation: "This transaction graph cannot be categorized safely."
                        )))
                        continue
                    } catch LocalFirstError.unsupportedTransferWrite {
                        dispositions.append(.blocked(TransactionBatchDispositionReason(
                            selection: selection,
                            explanation: "This transaction graph cannot be categorized safely."
                        )))
                        continue
                    }
                    if row.categoryID != categoryID {
                        messages.append(try builder.makeMessage(
                            dataset: "transactions",
                            row: selection.transactionID,
                            column: "category",
                            value: categoryID.map(LocalFirstSyncValue.string) ?? .null
                        ))
                        affectedIDs.insert(selection.transactionID)
                        learningIDs.insert(selection.transactionID)
                    }
                    if let account = row.accountID { accountIDs.insert(account) }
                    if let month = Self.monthID(row.dateValue) { monthIDs.insert(month) }
                case .delete:
                    if handledForDelete.contains(selection.transactionID) {
                        affectedIDs.insert(selection.transactionID)
                    } else {
                        let write = try batchDeleteTransactionMessages(
                            transactionID: selection.transactionID,
                            columns: columns,
                            db: db,
                            builder: &builder
                        )
                        messages += write.messages
                        affectedIDs.formUnion(write.affectedTransactionIDs)
                        handledForDelete.formUnion(write.affectedTransactionIDs)
                        accountIDs.formUnion(write.affectedAccountIDs)
                    }
                    if let account = row.accountID { accountIDs.insert(account) }
                    if let month = Self.monthID(row.dateValue) { monthIDs.insert(month) }
                }
            }

            let changedIDs = Array(Set(messages[messageStartIndex...].map(\.row))).sorted()
            let effect = TransactionBatchEffectSummary(
                selection: selection,
                affectedTransactionIDs: changedIDs,
                description: Self.effectDescription(intent, categoryID: categoryID)
            )
            if let reconciledRequirement {
                dispositions.append(.requiresAuthorization(TransactionBatchAuthorizationRequirement(
                    effect: effect,
                    reconciledTransactionIDs: reconciledRequirement.target,
                    pairedReconciledTransactionIDs: reconciledRequirement.paired
                )))
            } else {
                dispositions.append(.eligible(effect))
            }
        }

        let authorizationIDs = !requiredTargetReconciled.isEmpty || !requiredPairedReconciled.isEmpty
        let fingerprint = try transactionBatchFingerprint(
            context: context,
            intent: intent,
            selections: selections,
            loadedUngroupedTransactionIDs: loadedUngroupedTransactionIDs,
            snapshots: loadedRows,
            clearTarget: targetClear,
            affectedIDs: affectedIDs.sorted(),
            targetReconciled: requiredTargetReconciled.sorted(),
            pairedReconciled: requiredPairedReconciled.sorted()
        )
        let authorization = authorizationIDs
            ? TransactionBatchAuthorization(
                reviewID: id,
                reviewFingerprint: fingerprint,
                reconciledTransactionIDs: requiredTargetReconciled.sorted(),
                pairedReconciledTransactionIDs: requiredPairedReconciled.sorted()
            )
            : nil
        let rowChanges = try loadedRows.map { snapshot in
            TransactionBatchRowChange(
                before: Self.displayBatchSnapshot(snapshot),
                after: try projectedBatchSnapshot(snapshot, messages: messages, columns: columns)
            )
        }
        var renderedRowIDs = Set(selections.map(\.transactionID))
        for disposition in dispositions {
            switch disposition {
            case .eligible(let effect):
                renderedRowIDs.formUnion(effect.affectedTransactionIDs)
            case .requiresAuthorization(let requirement):
                renderedRowIDs.formUnion(requirement.effect.affectedTransactionIDs)
            case .skipped, .blocked:
                break
            }
        }
        let metadata = try transactionBatchReviewMetadata(
            renderedChanges: rowChanges.filter { renderedRowIDs.contains($0.id) },
            targetCategoryID: categoryID,
            db: db
        )
        let blockedCount = dispositions.filter { if case .blocked = $0 { true } else { false } }.count
        let canSubmit = blockedCount == 0 && !messages.isEmpty
        let review = TransactionBatchReview(
            id: id,
            context: context,
            intent: intent,
            selections: selections,
            loadedUngroupedTransactionIDs: loadedUngroupedTransactionIDs,
            dispositions: dispositions,
            rowChanges: rowChanges,
            metadata: metadata,
            clearTarget: targetClear,
            reviewFingerprint: fingerprint,
            effectsDescription: Self.batchEffectsDescription(
                intent: intent,
                selectedCount: selections.count,
                changedCount: affectedIDs.count,
                skippedCount: dispositions.filter { if case .skipped = $0 { true } else { false } }.count,
                categoryID: categoryID
            ),
            authorization: authorization,
            canSubmit: canSubmit
        )
        let descriptor = TransactionBatchActionDescriptor(
            operation: intent.actionKind,
            selectedTransactionIDs: selections.map(\.transactionID),
            snapshotTransactionIDs: graphSnapshots.keys.sorted(),
            affectedTransactionIDs: affectedIDs.sorted(),
            categoryID: categoryID,
            clearTarget: targetClear
        )
        return BatchPlan(
            review: review,
            messages: messages,
            descriptor: descriptor,
            affectedAccountIDs: accountIDs.filter { !$0.isEmpty }.sorted(),
            affectedMonthIDs: monthIDs.sorted(),
            affectedTransactionIDs: affectedIDs.sorted(),
            learningTransactionIDs: learningIDs
        )
    }

    private func aggregateBatchReconciledRows(
        transactionID: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> (target: Set<String>, paired: Set<String>) {
        guard let review = try reconciledMutationReview(
            transactionID: transactionID,
            columns: columns,
            db: db
        ) else { return ([], []) }
        return (
            Set(review.targetReconciledTransactionIDs),
            Set(review.pairedReconciledTransactionIDs)
        )
    }

    private func batchDeleteTransactionMessages(
        transactionID: String,
        columns: TransactionRowColumns,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        guard let existing = try transactionBatchSnapshot(id: transactionID, columns: columns, db: db),
              existing.tombstone != true else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        if existing.isParent == true || existing.isChild == true {
            return try deleteSplitFamilyMessages(
                transactionID: transactionID,
                columns: columns,
                db: db,
                builder: &builder
            )
        }
        var messages = [try tombstoneMessage(rowID: transactionID, builder: &builder)]
        var affectedIDs: Set<String> = [transactionID]
        var affectedAccounts = Set([existing.accountID].compactMap { $0 })
        if let pairedID = existing.transferID,
           let paired = try transactionBatchSnapshot(id: pairedID, columns: columns, db: db) {
            affectedIDs.insert(pairedID)
            if let account = paired.accountID { affectedAccounts.insert(account) }
            if paired.isChild == true, let transferColumn = columns.transferID {
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: transferColumn, value: .null))
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .null))
            } else {
                messages.append(try tombstoneMessage(rowID: pairedID, builder: &builder))
            }
        }
        return TransactionWriteResult(
            messages: messages,
            affectedAccountIDs: Array(affectedAccounts),
            affectedTransactionIDs: Array(affectedIDs)
        )
    }

    private func transactionBatchFingerprint(
        context: TransactionSelectionContext,
        intent: TransactionBatchIntent,
        selections: [TransactionSelectionIdentity],
        loadedUngroupedTransactionIDs: [String],
        snapshots: [TransactionBatchTransactionSnapshot],
        clearTarget: Bool?,
        affectedIDs: [String],
        targetReconciled: [String],
        pairedReconciled: [String]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rows = try encoder.encode(snapshots.sorted { $0.id < $1.id })
        let selectionText = selections.map { "\($0.transactionID)|\($0.familyRootID)|\($0.role)" }.joined(separator: ";")
        let intentText: String
        switch intent {
        case .clear: intentText = "clear|\(clearTarget.map { $0 ? "true" : "false" } ?? "unknown")"
        case .categorize(let categoryID): intentText = "categorize|\(categoryID ?? "none")"
        case .delete: intentText = "delete"
        }
        let scopeText: String
        switch context.scope {
        case .account(let accountID): scopeText = "account:\(accountID)"
        case .spending: scopeText = "spending"
        }
        let loadedText = loadedUngroupedTransactionIDs.joined(separator: ";")
        var input = Data("\(context.budgetID)|\(scopeText)|\(context.querySignature.stableSortKey)|\(intentText)|\(selectionText)|\(loadedText)|\(affectedIDs.joined(separator: ","))|\(targetReconciled.joined(separator: ","))|\(pairedReconciled.joined(separator: ","))|".utf8)
        input.append(rows)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func displayBatchSnapshot(
        _ snapshot: TransactionBatchTransactionSnapshot
    ) -> TransactionBatchRowSnapshot {
        TransactionBatchRowSnapshot(
            id: snapshot.id,
            accountID: snapshot.accountID,
            dateValue: snapshot.dateValue,
            amount: snapshot.amount,
            payeeID: snapshot.payeeID,
            categoryID: snapshot.categoryID,
            notes: snapshot.notes,
            cleared: snapshot.cleared,
            reconciled: snapshot.reconciled,
            tombstone: snapshot.tombstone,
            isParent: snapshot.isParent,
            isChild: snapshot.isChild,
            parentID: snapshot.parentID,
            transferID: snapshot.transferID,
            sortOrder: snapshot.sortOrder,
            startingBalance: snapshot.startingBalance,
            splitError: snapshot.splitError.flatMap { try? JSONDecoder().decode(SplitTransactionError.self, from: Data($0.utf8)) },
            scheduleID: snapshot.scheduleID,
            importedID: snapshot.importedID,
            importedPayee: snapshot.importedPayee ?? snapshot.importedDescription
        )
    }

    private func projectedBatchSnapshot(
        _ snapshot: TransactionBatchTransactionSnapshot,
        messages: [ActualSyncDecodedMessage],
        columns: TransactionRowColumns
    ) throws -> TransactionBatchRowSnapshot {
        var accountID = snapshot.accountID
        var dateValue = snapshot.dateValue
        var amount = snapshot.amount
        var payeeID = snapshot.payeeID
        var categoryID = snapshot.categoryID
        var notes = snapshot.notes
        var cleared = snapshot.cleared
        var reconciled = snapshot.reconciled
        var tombstone = snapshot.tombstone
        var isParent = snapshot.isParent
        var isChild = snapshot.isChild
        var parentID = snapshot.parentID
        var transferID = snapshot.transferID
        var sortOrder = snapshot.sortOrder
        var splitError = snapshot.splitError
        var startingBalance = snapshot.startingBalance
        var scheduleID = snapshot.scheduleID
        var importedID = snapshot.importedID
        var importedPayee = snapshot.importedPayee ?? snapshot.importedDescription

        for message in messages where message.row == snapshot.id {
            let value = try deserializeSyncValue(message.serializedValue)
            func string() -> String? {
                if case .string(let text) = value { return text }
                return nil
            }
            func integer() -> Int? {
                switch value {
                case .int(let number): Int(exactly: number)
                case .double(let number): Int(exactly: number)
                case .null, .string: nil
                }
            }
            func flag() -> Bool? { integer().map { $0 != 0 } }
            func double() -> Double? {
                switch value {
                case .int(let number): Double(number)
                case .double(let number): number
                case .null, .string: nil
                }
            }

            switch message.column {
            case columns.account: accountID = string()
            case "date": dateValue = integer()
            case "amount": amount = integer()
            case columns.payee: payeeID = string()
            case "category": categoryID = string()
            case "notes": notes = string()
            case "cleared": cleared = flag()
            case "reconciled": reconciled = flag()
            case "tombstone": tombstone = flag()
            case columns.isParent ?? "\0": isParent = flag()
            case columns.isChild ?? "\0": isChild = flag()
            case "parent_id": parentID = string()
            case columns.transferID ?? "\0": transferID = string()
            case columns.sortOrder ?? "\0": sortOrder = double()
            case "error": splitError = string()
            case "starting_balance_flag": startingBalance = flag()
            case "schedule": scheduleID = string()
            case "financial_id": importedID = string()
            case "imported_payee", "imported_description": importedPayee = string()
            default: break
            }
        }

        return TransactionBatchRowSnapshot(
            id: snapshot.id,
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
            startingBalance: startingBalance,
            splitError: splitError.flatMap { try? JSONDecoder().decode(SplitTransactionError.self, from: Data($0.utf8)) },
            scheduleID: scheduleID,
            importedID: importedID,
            importedPayee: importedPayee
        )
    }

    private func transactionBatchReviewMetadata(
        renderedChanges: [TransactionBatchRowChange],
        targetCategoryID: String?,
        db: Database
    ) throws -> TransactionBatchReviewMetadata {
        func names(in table: String) throws -> [String: String] {
            guard try tableExists(table, db: db) else { return [:] }
            let columns = try columnSet(for: table, db: db)
            guard columns.contains("id"), columns.contains("name") else { return [:] }
            return Dictionary(
                try Row.fetchAll(
                    db,
                    sql: "SELECT id, name FROM \(table) WHERE \(predicateForLiveRows(columns: columns))"
                ).compactMap { row -> (String, String)? in
                    guard let id = row["id"] as String? else { return nil }
                    return (id, row["name"] as String? ?? "")
                },
                uniquingKeysWith: { _, latest in latest }
            )
        }

        let accountNames = try names(in: "accounts")
        var payeeNames = try names(in: "payees")
        if try tableExists("payees", db: db) {
            let columns = try columnSet(for: "payees", db: db)
            if columns.contains("id"), columns.contains("transfer_acct") {
                for row in try Row.fetchAll(db, sql: "SELECT id, transfer_acct FROM payees") {
                    guard let id = row["id"] as String?,
                          payeeNames[id, default: ""].isEmpty,
                          let accountID = row["transfer_acct"] as String?,
                          let accountName = accountNames[accountID] else { continue }
                    payeeNames[id] = accountName
                }
            }
        }
        if try tableExists("payee_mapping", db: db) {
            let columns = try columnSet(for: "payee_mapping", db: db)
            let target = columns.contains("targetId")
                ? "targetId"
                : columns.contains("target_id") ? "target_id" : nil
            if columns.contains("id"), let target {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, \(quotedIdentifier(target)) AS target_id FROM payee_mapping"
                )
                for row in rows {
                    guard let aliasID = row["id"] as String?,
                          let targetID = row["target_id"] as String?,
                          let targetName = nonemptyBatchName(payeeNames[targetID]) else { continue }
                    payeeNames[aliasID] = targetName
                }
            }
        }
        let accountIDs = Set(renderedChanges.flatMap { [$0.before.accountID, $0.after.accountID].compactMap { $0 } })
        let payeeIDs = Set(renderedChanges.flatMap { [$0.before.payeeID, $0.after.payeeID].compactMap { $0 } })
        var categoryIDs = Set(renderedChanges.flatMap { [$0.before.categoryID, $0.after.categoryID].compactMap { $0 } })
        if let targetCategoryID { categoryIDs.insert(targetCategoryID) }
        return TransactionBatchReviewMetadata(
            currency: try budgetCurrency(db: db),
            accountNames: accountNames.filter { accountIDs.contains($0.key) },
            payeeNames: payeeNames.filter { payeeIDs.contains($0.key) },
            categoryNames: try names(in: "categories").filter { categoryIDs.contains($0.key) }
        )
    }

    private func nonemptyBatchName(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func monthID(_ dateValue: Int?) -> String? {
        guard let dateValue, dateValue > 0 else { return nil }
        let date = String(format: "%08d", dateValue)
        guard date.count == 8 else { return nil }
        return String(date.prefix(4)) + "-" + String(date.dropFirst(4).prefix(2))
    }

    private static func effectDescription(_ intent: TransactionBatchIntent, categoryID: String?) -> String {
        switch intent {
        case .clear: "Set the selected transaction's cleared state to the reviewed target."
        case .categorize: categoryID.map { "Set the selected transaction category to \($0)." } ?? "Remove the selected transaction category."
        case .delete: "Delete the selected transaction and the linked rows shown in this review."
        }
    }

    private static func batchEffectsDescription(
        intent: TransactionBatchIntent,
        selectedCount: Int,
        changedCount: Int,
        skippedCount: Int,
        categoryID: String?
    ) -> String {
        let base: String
        switch intent {
        case .clear: base = "Set the cleared state for \(changedCount) transaction rows."
        case .categorize: base = categoryID.map { "Categorize \(changedCount) transaction rows as \($0)." } ?? "Remove the category from \(changedCount) transaction rows."
        case .delete: base = "Delete \(changedCount) transaction rows."
        }
        let skipped = skippedCount > 0 ? " \(skippedCount) reconciled selected rows will be left unchanged." : ""
        let count = changedCount == selectedCount ? "" : " This includes linked rows beyond the \(selectedCount) selected entries."
        return base + skipped + count
    }
}

private extension TransactionBatchIntent {
    var actionKind: TransactionBatchActionKind {
        switch self {
        case .clear: .clear
        case .categorize: .categorize
        case .delete: .delete
        }
    }
}
