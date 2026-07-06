import Foundation

struct EnvelopeCategoryValue {
    var budgeted: Int = 0
    var spent: Int = 0
    var balance: Int = 0
    var carryover: Bool = false
}

struct TransactionBudgetSource {
    let tableExists: Bool
    let table: String
    let account: String
    let category: String
    let amount: String
    let month: String
    let livePredicate: String
}

struct ActualSyncDecodedMessage: Equatable, Sendable {
    let timestamp: String
    let dataset: String
    let row: String
    let column: String
    let serializedValue: String
}

struct PendingLocalSyncMessage: Equatable, Sendable {
    let message: ActualSyncDecodedMessage
    let baseTimestamp: String
    let attemptCount: Int
    let lastError: String?
}

enum ActualSyncSQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
}
