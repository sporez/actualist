import Foundation

/// Split / transfer / simple topology recorded with a transaction gesture.
/// Topology-changing edits are visible in History but not undoable in v1.
enum BudgetTransactionGraph: Equatable, Sendable {
    case simple
    case transfer(pairedID: String)
    case split(childIDs: [String])
}

enum BudgetTransactionGraphKind: String, Codable, Sendable {
    case simple
    case transfer
    case split
}

extension BudgetTransactionGraph {
    var kind: BudgetTransactionGraphKind {
        switch self {
        case .simple: .simple
        case .transfer: .transfer
        case .split: .split
        }
    }

    var relatedIDs: [String] {
        switch self {
        case .simple:
            []
        case .transfer(let pairedID):
            [pairedID]
        case .split(let childIDs):
            childIDs
        }
    }
}

/// Display-ready create / delete facts. Amounts are Actual minor units.
struct TransactionBudgetAction: Codable, Equatable, Sendable {
    var month: String
    var amount: Int
    var payeeName: String?
    var categoryID: String?
    var graph: BudgetTransactionGraphKind
    var transactionCount: Int
}

/// Display-ready edit facts.
struct EditTransactionBudgetAction: Codable, Equatable, Sendable {
    var month: String
    var amountBefore: Int
    var amountAfter: Int
    var payeeName: String?
    var graph: BudgetTransactionGraphKind
    var unsafeGraph: Bool
}

/// Display-ready categorize facts. One gesture, N transactions.
struct CategorizeBudgetAction: Codable, Equatable, Sendable {
    var month: String
    var categoryID: String
    var itemCount: Int
}

/// Live / recorded row used by edit inverses and the undo conflict check.
struct TransactionUndoSnapshot: Codable, Equatable, Sendable {
    var id: String
    var accountID: String
    var dateValue: Int
    var amount: Int
    var payeeID: String?
    var categoryID: String?
    var notes: String?
    var cleared: Bool
    var tombstone: Bool
    var transferID: String?
    var isParent: Bool
    var isChild: Bool
    var parentID: String?

    /// Field-level last-write-wins match for "still at after". Notes and
    /// cleared are included so a later untracked memo/cleared edit blocks
    /// instead of being overwritten.
    func matches(_ other: TransactionUndoSnapshot) -> Bool {
        id == other.id
            && accountID == other.accountID
            && dateValue == other.dateValue
            && amount == other.amount
            && payeeID == other.payeeID
            && categoryID == other.categoryID
            && notes == other.notes
            && cleared == other.cleared
            && tombstone == other.tombstone
            && transferID == other.transferID
            && isParent == other.isParent
            && isChild == other.isChild
            && parentID == other.parentID
    }
}

/// Category-learning rule writes that rode along with a transaction gesture.
struct BudgetActionLearningSideEffect: Codable, Equatable, Sendable {
    var createdRuleIDs: [String]
    var updatedRules: [BudgetActionLearningRuleUpdate]

    static let empty = BudgetActionLearningSideEffect(createdRuleIDs: [], updatedRules: [])

    var isEmpty: Bool { createdRuleIDs.isEmpty && updatedRules.isEmpty }
}

struct BudgetActionLearningRuleUpdate: Codable, Equatable, Sendable {
    var ruleID: String
    var beforeActionsJSON: String
    var afterActionsJSON: String
}

struct CreateTransactionInverse: Codable, Equatable, Sendable {
    var month: String
    var primaryTransactionID: String
    var transactionIDs: [String]
    var graph: BudgetTransactionGraph
    var createdPayeeID: String?
    var learning: BudgetActionLearningSideEffect
}

struct DeleteTransactionInverse: Codable, Equatable, Sendable {
    var month: String
    var transactionIDs: [String]
    var graph: BudgetTransactionGraph
}

struct EditTransactionInverse: Codable, Equatable, Sendable {
    var month: String
    var primaryBefore: TransactionUndoSnapshot
    var primaryAfter: TransactionUndoSnapshot
    var relatedBefore: [TransactionUndoSnapshot]
    var relatedAfter: [TransactionUndoSnapshot]
    var unsafeGraph: Bool
    var createdPayeeID: String?
    var learning: BudgetActionLearningSideEffect

    var allAfterSnapshots: [TransactionUndoSnapshot] {
        [primaryAfter] + relatedAfter
    }

    var allBeforeSnapshots: [TransactionUndoSnapshot] {
        [primaryBefore] + relatedBefore
    }
}

struct BudgetCategorizeFact: Codable, Equatable, Sendable {
    var transactionID: String
    var beforeCategoryID: String?
    var afterCategoryID: String
}

struct CategorizeTransactionInverse: Codable, Equatable, Sendable {
    var month: String
    var items: [BudgetCategorizeFact]
    var learning: BudgetActionLearningSideEffect
}

/// Submitted create gesture. IDs are known before the write transaction.
struct CreateTransactionDescriptor: Equatable, Sendable {
    var month: String
    var amount: Int
    var payeeName: String?
    var categoryID: String?
    var primaryTransactionID: String
    var transactionIDs: [String]
    var graph: BudgetTransactionGraph
    var createdPayeeID: String?
}

struct DeleteTransactionDescriptor: Equatable, Sendable {
    var month: String
    var amount: Int
    var payeeName: String?
    var categoryID: String?
    var transactionIDs: [String]
    var graph: BudgetTransactionGraph
}

struct EditTransactionDescriptor: Equatable, Sendable {
    var month: String
    var payeeName: String?
    var transactionID: String
    var affectedIDs: [String]
    var unsafeGraph: Bool
    var createdPayeeID: String?
}

struct CategorizeTransactionDescriptor: Equatable, Sendable {
    var month: String
    var categoryID: String
    var items: [BudgetCategorizeFact]
}

/// Money-flow vs notes/cleared-only. Notes-only and cleared-only edits are
/// recorded as metadata (Phase 4) and do not consume a money-flow slot.
enum BudgetTransactionLogging {
    static func metadataChanges(
        existing: ActualTransaction,
        draft: TransactionDraft
    ) -> (notes: Bool, cleared: Bool) {
        let existingNotes = existing.notes ?? ""
        let draftNotes = draft.notes ?? ""
        let notesChanged = existingNotes != draftNotes
        let existingCleared = existing.cleared?.boolValue ?? false
        let clearedChanged = existingCleared != draft.cleared
        return (notesChanged, clearedChanged)
    }

    static func shouldRecordUpdate(
        existing: ActualTransaction,
        draft: TransactionDraft,
        resolvedPayeeID: String?
    ) -> Bool {
        if existing.account != draft.accountID {
            return true
        }
        if existing.date != actualDateString(draft.date) {
            return true
        }
        if (existing.amount ?? 0) != draft.amountMinorUnits {
            return true
        }
        if existing.payee != resolvedPayeeID {
            return true
        }
        if existing.category != draft.categoryID {
            return true
        }
        if existing.isParent != draft.isSplit {
            return true
        }
        if draft.isSplit {
            if existing.subtransactions.count != draft.splits.count {
                return true
            }
            for (child, split) in zip(existing.subtransactions, draft.splits) {
                if (child.amount ?? 0) != split.amountMinorUnits {
                    return true
                }
                if child.category != split.categoryID {
                    return true
                }
                if case .value(let splitPayeeID) = split.payeeID, child.payee != splitPayeeID {
                    return true
                }
            }
        }
        return false
    }

    static func topologyChanged(
        existing: BudgetDatabase.ExistingTransactionState,
        draft: TransactionDraft,
        primaryID: String,
        affectedIDs: [String]
    ) -> Bool {
        if (existing.transferID != nil) != draft.isTransfer {
            return true
        }
        if existing.isParent != draft.isSplit {
            return true
        }
        let beforeRelated = Set(existing.childIDs + [existing.transferID].compactMap { $0 })
        let afterRelated = Set(affectedIDs).subtracting([primaryID])
        return beforeRelated != afterRelated
    }

    private static func actualDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension BudgetTransactionGraph: Codable {
    private enum GraphKind: String, Codable {
        case simple
        case transfer
        case split
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case pairedID
        case childIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(GraphKind.self, forKey: .type) {
        case .simple:
            self = .simple
        case .transfer:
            self = .transfer(pairedID: try container.decode(String.self, forKey: .pairedID))
        case .split:
            self = .split(childIDs: try container.decode([String].self, forKey: .childIDs))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .simple:
            try container.encode(GraphKind.simple, forKey: .type)
        case .transfer(let pairedID):
            try container.encode(GraphKind.transfer, forKey: .type)
            try container.encode(pairedID, forKey: .pairedID)
        case .split(let childIDs):
            try container.encode(GraphKind.split, forKey: .type)
            try container.encode(childIDs, forKey: .childIDs)
        }
    }
}
