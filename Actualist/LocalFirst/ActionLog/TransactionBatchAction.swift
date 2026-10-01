import Foundation

enum TransactionBatchActionKind: String, Codable, Sendable {
    case clear
    case categorize
    case delete
}

struct TransactionBatchBudgetAction: Codable, Equatable, Sendable {
    let operation: TransactionBatchActionKind
    let selectedCount: Int
    let changedCount: Int
    let clearTarget: Bool?
    let categoryID: String?
}

/// Full physical row state needed to refuse a stale undo and restore a batch.
/// `columns` distinguishes a schema-absent cell from a stored SQL NULL.
struct TransactionBatchTransactionSnapshot: Codable, Equatable, Sendable {
    let id: String
    let columns: [String]
    let accountID: String?
    let dateValue: Int?
    let amount: Int?
    let payeeID: String?
    let categoryID: String?
    let notes: String?
    let cleared: Bool?
    let reconciled: Bool?
    let tombstone: Bool?
    let isParent: Bool?
    let isChild: Bool?
    let parentID: String?
    let transferID: String?
    let sortOrder: Double?
    let splitError: String?
    let startingBalance: Bool?
    let scheduleID: String?
    let importedID: String?
    let importedPayee: String?
    let importedDescription: String?

    func matches(_ other: TransactionBatchTransactionSnapshot) -> Bool {
        id == other.id
            && columns == other.columns
            && accountID == other.accountID
            && dateValue == other.dateValue
            && amount == other.amount
            && payeeID == other.payeeID
            && categoryID == other.categoryID
            && notes == other.notes
            && cleared == other.cleared
            && reconciled == other.reconciled
            && tombstone == other.tombstone
            && isParent == other.isParent
            && isChild == other.isChild
            && parentID == other.parentID
            && transferID == other.transferID
            && sortOrder == other.sortOrder
            && splitError == other.splitError
            && startingBalance == other.startingBalance
            && scheduleID == other.scheduleID
            && importedID == other.importedID
            && importedPayee == other.importedPayee
            && importedDescription == other.importedDescription
    }
}

struct TransactionBatchActionDescriptor: Equatable, Sendable {
    let operation: TransactionBatchActionKind
    let selectedTransactionIDs: [String]
    let snapshotTransactionIDs: [String]
    let affectedTransactionIDs: [String]
    let categoryID: String?
    let clearTarget: Bool?
}

struct TransactionBatchTransactionInverse: Codable, Equatable, Sendable {
    let operation: TransactionBatchActionKind
    let selectedTransactionIDs: [String]
    var beforeSnapshots: [TransactionBatchTransactionSnapshot]
    var afterSnapshots: [TransactionBatchTransactionSnapshot]
    var learning: BudgetActionLearningSideEffect
}
