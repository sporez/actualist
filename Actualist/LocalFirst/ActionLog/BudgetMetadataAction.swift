import Foundation

extension BudgetActionKind {
    /// v1 History undo and the 25-row retention cap apply only to money-flow
    /// gestures. Metadata rows are visible in the same log without consuming a
    /// slot or stealing LIFO (Phase 4 / Q10).
    var isMoneyFlow: Bool {
        switch self {
        case .assign, .move, .template,
                .createTransaction, .editTransaction, .deleteTransaction, .categorize:
            true
        case .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            false
        }
    }

    static var moneyFlowRawValues: [String] {
        [
            assign.rawValue,
            move.rawValue,
            template.rawValue,
            createTransaction.rawValue,
            editTransaction.rawValue,
            deleteTransaction.rawValue,
            categorize.rawValue
        ]
    }
}

enum PayeeBudgetOperation: String, Codable, Sendable {
    case create
    case rename
    case delete
    case merge
    case update
}

struct PayeeBudgetAction: Codable, Equatable, Sendable {
    var operation: PayeeBudgetOperation
    var names: [String]
}

enum RuleBudgetOperation: String, Codable, Sendable {
    case create
    case update
    case delete
}

struct RuleBudgetAction: Codable, Equatable, Sendable {
    var operation: RuleBudgetOperation
}

struct AccountBudgetAction: Codable, Equatable, Sendable {
    var name: String
    var offbudget: Bool
}

struct CarryoverBudgetAction: Codable, Equatable, Sendable {
    var startMonth: String
    var after: Bool
    var categoryCount: Int
}

struct LearningPrefBudgetAction: Codable, Equatable, Sendable {
    var after: Bool
}

struct TransactionMetadataBudgetAction: Codable, Equatable, Sendable {
    var month: String
    var payeeName: String?
    var notesChanged: Bool
    var clearedChanged: Bool
}

struct PayeeActionDescriptor: Equatable, Sendable {
    var operation: PayeeBudgetOperation
    var names: [String]
}

struct RuleActionDescriptor: Equatable, Sendable {
    var operation: RuleBudgetOperation
}

struct AccountActionDescriptor: Equatable, Sendable {
    var name: String
    var offbudget: Bool
}

struct CarryoverActionDescriptor: Equatable, Sendable {
    var startMonth: String
    var after: Bool
    var categoryCount: Int
}

struct LearningPrefActionDescriptor: Equatable, Sendable {
    var after: Bool
}

struct TransactionMetadataActionDescriptor: Equatable, Sendable {
    var month: String
    var payeeName: String?
    var notesChanged: Bool
    var clearedChanged: Bool
}
