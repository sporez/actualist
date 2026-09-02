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
        }
    }
}

/// Result of running an inverse against live cells.
enum BudgetActionUndoEvaluation: Equatable, Sendable {
    /// `categoryID` → absolute budgeted amount to write. The undo commits
    /// these through the normal assign builder.
    case clean(targets: [String: Int])
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

    var actionID: String
    var month: String
    var entries: [Entry]
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
        liveBudgeted: [String: Int?]
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
            return .clean(targets: [assign.categoryID: target])

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
            return .clean(targets: targets)

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
            return .clean(targets: targets)
        }
    }

    private static func restoredAmount(_ amount: Int) -> Int? {
        abs(amount) <= Money.maximumUserAmountMinorUnits ? amount : nil
    }
}
