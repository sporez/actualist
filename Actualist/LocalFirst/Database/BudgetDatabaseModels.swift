import Foundation

/// Actual stores envelope amounts in `zero_budgets` and tracking amounts in
/// `reflect_budgets`. Match `getBudgetTable()` rather than hard-coding either name.
enum BudgetTable: String {
    case envelope = "zero_budgets"
    case tracking = "reflect_budgets"
}

struct BudgetCategoryValue {
    var budgeted: Int = 0
    var spent: Int = 0
    var balance: Int = 0
    var carryover: Bool = false
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

/// Financial data, mode (through the typed summary), currency and discovered
/// months come from the same SQLite read transaction.
struct BudgetFinancialSnapshot: Sendable {
    let month: BudgetMonth
    let currency: BudgetCurrency
    let availableMonths: [String]
}
