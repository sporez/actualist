import Foundation

/// A money-flow gesture recorded in the local-only `actualist_action_log`
/// table. One user gesture is one row (a multi-leg move is one row), never one
/// CRDT message. The table lives inside the imported budget SQLite, is wiped on
/// reimport, and must never be synced, logged, or exported.
enum BudgetActionKind: String, Codable, Sendable {
    case assign
    case move
    case template
    case createTransaction
    case editTransaction
    case deleteTransaction
    case categorize
    case payee
    case rule
    case account
    case carryover
    case learningPref
    case transactionMetadata
}

enum BudgetActionStatus: String, Codable, Sendable {
    case applied
    case undone
    case blocked
    case expired
}

enum BudgetActionSource: String, Codable, Sendable {
    case ui
    case shortcuts
}

/// Nil category means To Budget.
struct BudgetMoveLeg: Codable, Equatable, Sendable {
    var fromCategoryID: String?
    var toCategoryID: String?
    var amount: Int
}

/// Assign facts shared by the display summary and the undo inverse: under LIFO
/// undo the last assignment is still at `after`, so undo writes `before`.
struct AssignBudgetAction: Codable, Equatable, Sendable {
    var month: String
    var categoryID: String
    var before: Int
    var after: Int
}

/// Display summary of a move gesture (one gesture, N legs).
struct MoveBudgetAction: Codable, Equatable, Sendable {
    var month: String
    var legs: [BudgetMoveLeg]
}

/// One category's resulting assignment produced by the template engine; the
/// forward write path pairs it with the live before-value to form a
/// `BudgetTemplateAssignmentFact`.
struct BudgetTemplateAssignment: Equatable, Sendable {
    var categoryID: String
    var amount: Int
}

/// One category's assignment inside a template apply.
struct BudgetTemplateAssignmentFact: Codable, Equatable, Sendable {
    var categoryID: String
    var before: Int
    var after: Int
}

/// A template apply is a batch of assignments: shared by the display summary
/// and the undo inverse, which restores `before` per category (same policy as
/// assign).
struct TemplateBudgetAction: Codable, Equatable, Sendable {
    var month: String
    var mode: BudgetTemplateApplicationMode
    var entries: [BudgetTemplateAssignmentFact]
}

/// Display-ready gesture facts. Amounts are Actual minor units. Kept typed and
/// separate from the inverse so later action kinds can diverge (transaction
/// graphs, payee edits) without a schema change.
enum BudgetActionSummary: Equatable, Sendable {
    case assign(AssignBudgetAction)
    case move(MoveBudgetAction)
    case template(TemplateBudgetAction)
    case createTransaction(TransactionBudgetAction)
    case editTransaction(EditTransactionBudgetAction)
    case deleteTransaction(TransactionBudgetAction)
    case categorize(CategorizeBudgetAction)
    case payee(PayeeBudgetAction)
    case rule(RuleBudgetAction)
    case account(AccountBudgetAction)
    case carryover(CarryoverBudgetAction)
    case learningPref(LearningPrefBudgetAction)
    case transactionMetadata(TransactionMetadataBudgetAction)
}

/// A persisted money-flow gesture, decoded from `actualist_action_log`.
struct BudgetActionRecord: Equatable, Sendable {
    var id: String
    var createdAt: Date
    var kind: BudgetActionKind
    var status: BudgetActionStatus
    var month: String?
    var summary: BudgetActionSummary
    var inverse: BudgetActionInverse
    var affectedCategoryIDs: [String]
    var forwardTimestampStart: String?
    var forwardTimestampEnd: String?
    var source: BudgetActionSource
}

extension BudgetActionSummary: Codable {
    private enum SummaryKind: String, Codable {
        case assign
        case move
        case template
        case createTransaction
        case editTransaction
        case deleteTransaction
        case categorize
        case payee
        case rule
        case account
        case carryover
        case learningPref
        case transactionMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .payload)
        switch try container.decode(SummaryKind.self, forKey: .type) {
        case .assign:
            self = .assign(try payload.decode(AssignBudgetAction.self, forKey: .payload))
        case .move:
            self = .move(try payload.decode(MoveBudgetAction.self, forKey: .payload))
        case .template:
            self = .template(try payload.decode(TemplateBudgetAction.self, forKey: .payload))
        case .createTransaction:
            self = .createTransaction(try payload.decode(TransactionBudgetAction.self, forKey: .payload))
        case .editTransaction:
            self = .editTransaction(try payload.decode(EditTransactionBudgetAction.self, forKey: .payload))
        case .deleteTransaction:
            self = .deleteTransaction(try payload.decode(TransactionBudgetAction.self, forKey: .payload))
        case .categorize:
            self = .categorize(try payload.decode(CategorizeBudgetAction.self, forKey: .payload))
        case .payee:
            self = .payee(try payload.decode(PayeeBudgetAction.self, forKey: .payload))
        case .rule:
            self = .rule(try payload.decode(RuleBudgetAction.self, forKey: .payload))
        case .account:
            self = .account(try payload.decode(AccountBudgetAction.self, forKey: .payload))
        case .carryover:
            self = .carryover(try payload.decode(CarryoverBudgetAction.self, forKey: .payload))
        case .learningPref:
            self = .learningPref(try payload.decode(LearningPrefBudgetAction.self, forKey: .payload))
        case .transactionMetadata:
            self = .transactionMetadata(try payload.decode(TransactionMetadataBudgetAction.self, forKey: .payload))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var payload = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .payload)
        switch self {
        case .assign(let assign):
            try container.encode(SummaryKind.assign, forKey: .type)
            try payload.encode(assign, forKey: .payload)
        case .move(let move):
            try container.encode(SummaryKind.move, forKey: .type)
            try payload.encode(move, forKey: .payload)
        case .template(let template):
            try container.encode(SummaryKind.template, forKey: .type)
            try payload.encode(template, forKey: .payload)
        case .createTransaction(let create):
            try container.encode(SummaryKind.createTransaction, forKey: .type)
            try payload.encode(create, forKey: .payload)
        case .editTransaction(let edit):
            try container.encode(SummaryKind.editTransaction, forKey: .type)
            try payload.encode(edit, forKey: .payload)
        case .deleteTransaction(let delete):
            try container.encode(SummaryKind.deleteTransaction, forKey: .type)
            try payload.encode(delete, forKey: .payload)
        case .categorize(let categorize):
            try container.encode(SummaryKind.categorize, forKey: .type)
            try payload.encode(categorize, forKey: .payload)
        case .payee(let payee):
            try container.encode(SummaryKind.payee, forKey: .type)
            try payload.encode(payee, forKey: .payload)
        case .rule(let rule):
            try container.encode(SummaryKind.rule, forKey: .type)
            try payload.encode(rule, forKey: .payload)
        case .account(let account):
            try container.encode(SummaryKind.account, forKey: .type)
            try payload.encode(account, forKey: .payload)
        case .carryover(let carryover):
            try container.encode(SummaryKind.carryover, forKey: .type)
            try payload.encode(carryover, forKey: .payload)
        case .learningPref(let learning):
            try container.encode(SummaryKind.learningPref, forKey: .type)
            try payload.encode(learning, forKey: .payload)
        case .transactionMetadata(let metadata):
            try container.encode(SummaryKind.transactionMetadata, forKey: .type)
            try payload.encode(metadata, forKey: .payload)
        }
    }
}
