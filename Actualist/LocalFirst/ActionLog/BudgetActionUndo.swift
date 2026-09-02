import Foundation

/// Why a recorded gesture cannot be undone right now. Typed; user-facing copy
/// lives in the History presentation layer.
enum BudgetActionUndoBlock: Equatable, Sendable {
    /// Record is no longer `applied` (already undone by a previous undo).
    case alreadyUndone
    /// A category named by the inverse no longer exists.
    case categoryMissing
    /// A live cell no longer matches the recorded after-state (later local or
    /// synced change). Undo would clobber it, so it refuses.
    case changedSinceApplied
    /// Restoring the recorded amount would exceed the supported range.
    case amountOutOfRange
    /// A transaction named by the inverse no longer exists.
    case transactionMissing
    /// Undo create, but the transaction is already tombstoned.
    case alreadyTombstoned
    /// Undo delete, but the transaction is already live again.
    case alreadyLive
    /// A later edit owns a field this inverse would restore.
    case transactionChanged
    /// Split / transfer graph no longer matches the recorded shape.
    case graphRewritten
    /// A category-learning rule that rode along with this gesture changed later.
    case sideEffectChanged
    /// Phase 4 metadata is visible in History but v1 LIFO undo is money-flow only.
    case notOfferedFromHistory

    /// Shared copy for undo refusals surfaced through `LocalFirstError`
    /// (store-thrown) and the History review sheet.
    var userFacingReason: String {
        switch self {
        case .alreadyUndone:
            "This action was already undone."
        case .categoryMissing:
            "A category from this action no longer exists."
        case .changedSinceApplied:
            "Something changed a category after this action. Undo would overwrite the newer change, so it was refused."
        case .amountOutOfRange:
            "Undo would restore an amount too large to save."
        case .transactionMissing:
            "A transaction from this action no longer exists."
        case .transactionChanged:
            "Something changed this transaction after this action. Undo would overwrite the newer change, so it was refused."
        case .alreadyTombstoned:
            "This transaction was already deleted."
        case .alreadyLive:
            "This transaction is already restored."
        case .graphRewritten:
            "This transaction was split, transferred, or rewritten after this action. Undo would not be safe."
        case .sideEffectChanged:
            "A category-learning rule from this action changed later. Undo would not be safe."
        case .notOfferedFromHistory:
            "This change isn't undone from History."
        }
    }
}

/// Compensating write produced by a clean invert. The undo commit turns this
/// into CRDT messages through the normal builders.
enum BudgetActionUndoPlan: Equatable, Sendable {
    /// `categoryID` → absolute budgeted amount to write.
    case assignments(targets: [String: Int])
    case tombstoneTransactions(
        transactionIDs: [String],
        createdPayeeID: String?,
        learning: BudgetActionLearningSideEffect
    )
    case unTombstoneTransactions(transactionIDs: [String])
    case restoreSnapshots(
        snapshots: [TransactionUndoSnapshot],
        createdPayeeID: String?,
        learning: BudgetActionLearningSideEffect
    )
    case restoreCategories(
        items: [BudgetCategorizeFact],
        learning: BudgetActionLearningSideEffect
    )
}

/// Result of running an inverse against live cells.
enum BudgetActionUndoEvaluation: Equatable, Sendable {
    case clean(BudgetActionUndoPlan)
    case blocked(BudgetActionUndoBlock)
}

/// What the undo review shows before the user confirms: current → proposed per
/// category, or the typed block reason with no proposed writes.
struct BudgetActionUndoPreview: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var categoryID: String
        var current: Int
        var proposed: Int
    }

    struct TransactionLine: Equatable, Sendable {
        enum Effect: String, Equatable, Sendable {
            case delete
            case restore
            case recategorize
            case edit
        }

        var id: String
        var payeeName: String?
        var amount: Int?
        var currentCategoryID: String?
        var proposedCategoryID: String?
        var effect: Effect
    }

    var actionID: String
    var month: String
    var entries: [Entry]
    var transactionLines: [TransactionLine] = []
    var block: BudgetActionUndoBlock?

    var isUndoable: Bool {
        block == nil
    }
}

/// Pure conflict check + target computation shared by the undo preview and the
/// atomic undo commit. Under LIFO undo the affected cells are still at their
/// recorded after-state; anything else means a later local or synced change
/// owns them and the undo refuses instead of clobbering.
enum BudgetActionUndo {
    /// `liveBudgeted` covers every category id the inverse touches; a `nil`
    /// value means the category no longer exists.
    static func evaluate(
        record: BudgetActionRecord,
        liveBudgeted: [String: Int?],
        liveTransactions: [String: TransactionUndoSnapshot?] = [:],
        liveRuleActions: [String: String?] = [:]
    ) -> BudgetActionUndoEvaluation {
        guard record.status == .applied else {
            return .blocked(.alreadyUndone)
        }

        switch record.inverse {
        case .assign(let assign):
            guard let live = liveBudgeted[assign.categoryID] ?? nil else {
                return .blocked(.categoryMissing)
            }
            guard live == assign.after else {
                return .blocked(.changedSinceApplied)
            }
            guard let target = restoredAmount(assign.before) else {
                return .blocked(.amountOutOfRange)
            }
            return .clean(.assignments(targets: [assign.categoryID: target]))

        case .move(let move):
            var deltas: [String: Int] = [:]
            for leg in move.legs {
                if let fromCategoryID = leg.fromCategoryID {
                    deltas[fromCategoryID, default: 0] -= leg.amount
                }
                if let toCategoryID = leg.toCategoryID {
                    deltas[toCategoryID, default: 0] += leg.amount
                }
            }
            var targets: [String: Int] = [:]
            for (categoryID, previous) in move.previousBudgeted {
                guard let live = liveBudgeted[categoryID] ?? nil else {
                    return .blocked(.categoryMissing)
                }
                let (expected, overflow) = previous.addingReportingOverflow(deltas[categoryID] ?? 0)
                guard !overflow, live == expected else {
                    return .blocked(.changedSinceApplied)
                }
                guard let target = restoredAmount(previous) else {
                    return .blocked(.amountOutOfRange)
                }
                targets[categoryID] = target
            }
            return .clean(.assignments(targets: targets))

        case .template(let template):
            var targets: [String: Int] = [:]
            for entry in template.entries {
                guard let live = liveBudgeted[entry.categoryID] ?? nil else {
                    return .blocked(.categoryMissing)
                }
                guard live == entry.after else {
                    return .blocked(.changedSinceApplied)
                }
                guard let target = restoredAmount(entry.before) else {
                    return .blocked(.amountOutOfRange)
                }
                targets[entry.categoryID] = target
            }
            return .clean(.assignments(targets: targets))

        case .createTransaction(let create):
            if let block = learningBlock(create.learning, liveRuleActions: liveRuleActions) {
                return .blocked(block)
            }
            if let block = createGraphBlock(create, live: liveTransactions) {
                return .blocked(block)
            }
            return .clean(.tombstoneTransactions(
                transactionIDs: create.transactionIDs,
                createdPayeeID: create.createdPayeeID,
                learning: create.learning
            ))

        case .deleteTransaction(let delete):
            if let block = deleteGraphBlock(delete, live: liveTransactions) {
                return .blocked(block)
            }
            return .clean(.unTombstoneTransactions(transactionIDs: delete.transactionIDs))

        case .editTransaction(let edit):
            if edit.unsafeGraph {
                return .blocked(.graphRewritten)
            }
            if let block = learningBlock(edit.learning, liveRuleActions: liveRuleActions) {
                return .blocked(block)
            }
            for snapshot in edit.allAfterSnapshots {
                guard let live = liveTransactions[snapshot.id] ?? nil else {
                    return .blocked(.transactionMissing)
                }
                if live.tombstone {
                    return .blocked(.alreadyTombstoned)
                }
                guard live.matches(snapshot) else {
                    return .blocked(.transactionChanged)
                }
            }
            return .clean(.restoreSnapshots(
                snapshots: edit.allBeforeSnapshots,
                createdPayeeID: edit.createdPayeeID,
                learning: edit.learning
            ))

        case .categorize(let categorize):
            if let block = learningBlock(categorize.learning, liveRuleActions: liveRuleActions) {
                return .blocked(block)
            }
            var restorables: [BudgetCategorizeFact] = []
            var blockedCount = 0
            for item in categorize.items {
                guard let live = liveTransactions[item.transactionID] ?? nil else {
                    blockedCount += 1
                    continue
                }
                if live.tombstone {
                    blockedCount += 1
                    continue
                }
                if live.categoryID != item.afterCategoryID {
                    blockedCount += 1
                    continue
                }
                restorables.append(item)
            }
            guard !restorables.isEmpty else {
                return .blocked(blockedCount == categorize.items.count ? .transactionChanged : .transactionMissing)
            }
            return .clean(.restoreCategories(items: restorables, learning: categorize.learning))

        case .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            return .blocked(.notOfferedFromHistory)
        }
    }

    private static func learningBlock(
        _ learning: BudgetActionLearningSideEffect,
        liveRuleActions: [String: String?]
    ) -> BudgetActionUndoBlock? {
        guard !learning.isEmpty else { return nil }
        for ruleID in learning.createdRuleIDs {
            guard liveRuleActions[ruleID] ?? nil != nil else {
                return .sideEffectChanged
            }
        }
        for update in learning.updatedRules {
            guard let live = liveRuleActions[update.ruleID] ?? nil else {
                return .sideEffectChanged
            }
            if live != update.afterActionsJSON {
                return .sideEffectChanged
            }
        }
        return nil
    }

    private static func createGraphBlock(
        _ create: CreateTransactionInverse,
        live: [String: TransactionUndoSnapshot?]
    ) -> BudgetActionUndoBlock? {
        for id in create.transactionIDs {
            guard let snapshot = live[id] ?? nil else {
                return .transactionMissing
            }
            if snapshot.tombstone {
                return .alreadyTombstoned
            }
        }
        return graphMismatch(create.graph, primaryID: create.primaryTransactionID, live: live)
    }

    private static func deleteGraphBlock(
        _ delete: DeleteTransactionInverse,
        live: [String: TransactionUndoSnapshot?]
    ) -> BudgetActionUndoBlock? {
        for id in delete.transactionIDs {
            guard let snapshot = live[id] ?? nil else {
                return .transactionMissing
            }
            if !snapshot.tombstone {
                return .alreadyLive
            }
        }
        return nil
    }

    private static func graphMismatch(
        _ graph: BudgetTransactionGraph,
        primaryID: String,
        live: [String: TransactionUndoSnapshot?]
    ) -> BudgetActionUndoBlock? {
        guard let primary = live[primaryID] ?? nil else {
            return .transactionMissing
        }
        switch graph {
        case .simple:
            if primary.isParent || primary.isChild || primary.transferID != nil {
                return .graphRewritten
            }
        case .transfer(let pairedID):
            if primary.transferID != pairedID {
                return .graphRewritten
            }
            guard let pair = live[pairedID] ?? nil, !pair.tombstone else {
                return .graphRewritten
            }
        case .split(let childIDs):
            if !primary.isParent {
                return .graphRewritten
            }
            let liveChildren = Set(
                live.values.compactMap { snapshot -> String? in
                    guard let snapshot, snapshot.parentID == primaryID, !snapshot.tombstone else {
                        return nil
                    }
                    return snapshot.id
                }
            )
            if liveChildren != Set(childIDs) {
                return .graphRewritten
            }
        }
        return nil
    }

    private static func restoredAmount(_ amount: Int) -> Int? {
        abs(amount) <= Money.maximumUserAmountMinorUnits ? amount : nil
    }
}
