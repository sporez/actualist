import Foundation

/// Typed undo plan for a move gesture. The undo re-interprets this against
/// current SQLite at undo time; it is never a stored CRDT draft. Under LIFO
/// undo nothing newer exists on these cells, so writing `previousBudgeted`
/// equals reversing `legs`; the legs are kept because later selective undo
/// (Model B) needs them.
struct MoveBudgetActionInverse: Codable, Equatable, Sendable {
    var month: String
    var legs: [BudgetMoveLeg]
    /// Category id → budgeted amount before the gesture. To Budget legs carry a
    /// nil category and need no entry; To Budget is derived, not a stored cell.
    var previousBudgeted: [String: Int]
}

/// Typed inverse captured inside the write transaction, never a bag of pending
/// message drafts.
enum BudgetActionInverse: Equatable, Sendable {
    case assign(AssignBudgetAction)
    case move(MoveBudgetActionInverse)
    case template(TemplateBudgetAction)
    case createTransaction(CreateTransactionInverse)
    case editTransaction(EditTransactionInverse)
    case deleteTransaction(DeleteTransactionInverse)
    case categorize(CategorizeTransactionInverse)
    case payee(PayeeBudgetAction)
    case rule(RuleBudgetAction)
    case account(AccountBudgetAction)
    case carryover(CarryoverBudgetAction)
    case learningPref(LearningPrefBudgetAction)
    case transactionMetadata(TransactionMetadataBudgetAction)
}

extension BudgetActionInverse {
    /// The budget month the gesture wrote into. All v1 kinds are month-scoped.
    var month: String {
        switch self {
        case .assign(let assign):
            return assign.month
        case .move(let move):
            return move.month
        case .template(let template):
            return template.month
        case .createTransaction(let create):
            return create.month
        case .editTransaction(let edit):
            return edit.month
        case .deleteTransaction(let delete):
            return delete.month
        case .categorize(let categorize):
            return categorize.month
        case .payee, .rule, .account, .learningPref:
            return ""
        case .carryover(let carryover):
            return carryover.startMonth
        case .transactionMetadata(let metadata):
            return metadata.month
        }
    }

    var learning: BudgetActionLearningSideEffect {
        switch self {
        case .createTransaction(let create): create.learning
        case .editTransaction(let edit): edit.learning
        case .categorize(let categorize): categorize.learning
        case .assign, .move, .template, .deleteTransaction,
                .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            .empty
        }
    }

    var transactionIDs: [String] {
        switch self {
        case .createTransaction(let create):
            create.transactionIDs
        case .deleteTransaction(let delete):
            delete.transactionIDs
        case .editTransaction(let edit):
            edit.allAfterSnapshots.map(\.id)
        case .categorize(let categorize):
            categorize.items.map(\.transactionID)
        case .assign, .move, .template,
                .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            []
        }
    }

    func appending(learning: BudgetActionLearningSideEffect) -> BudgetActionInverse {
        guard !learning.isEmpty else { return self }
        switch self {
        case .createTransaction(var create):
            create.learning = learning
            return .createTransaction(create)
        case .editTransaction(var edit):
            edit.learning = learning
            return .editTransaction(edit)
        case .categorize(var categorize):
            categorize.learning = learning
            return .categorize(categorize)
        case .assign, .move, .template, .deleteTransaction,
                .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            return self
        }
    }
}

/// A user gesture as submitted, before live cells are read. The write path
/// turns this into a summary and inverse inside the commit transaction so a
/// concurrent Shortcuts write cannot race the before-values.
enum BudgetActionDescriptor: Equatable, Sendable {
    case assign(month: String, categoryID: String, budgeted: Int)
    case move(month: String, legs: [BudgetMoveLeg])
    /// `assignments` are the engine's resulting amounts; the commit pairs them
    /// with live before-values to build the recorded facts. Skip recording
    /// when empty (a goal-only or orphan-cleanup write moved no money).
    case template(month: String, mode: BudgetTemplateApplicationMode, assignments: [BudgetTemplateAssignment])
    case createTransaction(CreateTransactionDescriptor)
    case editTransaction(EditTransactionDescriptor)
    case deleteTransaction(DeleteTransactionDescriptor)
    case categorize(CategorizeTransactionDescriptor)
    case payee(PayeeActionDescriptor)
    case rule(RuleActionDescriptor)
    case account(AccountActionDescriptor)
    case carryover(CarryoverActionDescriptor)
    case learningPref(LearningPrefActionDescriptor)
    case transactionMetadata(TransactionMetadataActionDescriptor)
}

extension BudgetActionInverse: Codable {
    private enum InverseKind: String, Codable {
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
        switch try container.decode(InverseKind.self, forKey: .type) {
        case .assign:
            self = .assign(try payload.decode(AssignBudgetAction.self, forKey: .payload))
        case .move:
            self = .move(try payload.decode(MoveBudgetActionInverse.self, forKey: .payload))
        case .template:
            self = .template(try payload.decode(TemplateBudgetAction.self, forKey: .payload))
        case .createTransaction:
            self = .createTransaction(try payload.decode(CreateTransactionInverse.self, forKey: .payload))
        case .editTransaction:
            self = .editTransaction(try payload.decode(EditTransactionInverse.self, forKey: .payload))
        case .deleteTransaction:
            self = .deleteTransaction(try payload.decode(DeleteTransactionInverse.self, forKey: .payload))
        case .categorize:
            self = .categorize(try payload.decode(CategorizeTransactionInverse.self, forKey: .payload))
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
            try container.encode(InverseKind.assign, forKey: .type)
            try payload.encode(assign, forKey: .payload)
        case .move(let move):
            try container.encode(InverseKind.move, forKey: .type)
            try payload.encode(move, forKey: .payload)
        case .template(let template):
            try container.encode(InverseKind.template, forKey: .type)
            try payload.encode(template, forKey: .payload)
        case .createTransaction(let create):
            try container.encode(InverseKind.createTransaction, forKey: .type)
            try payload.encode(create, forKey: .payload)
        case .editTransaction(let edit):
            try container.encode(InverseKind.editTransaction, forKey: .type)
            try payload.encode(edit, forKey: .payload)
        case .deleteTransaction(let delete):
            try container.encode(InverseKind.deleteTransaction, forKey: .type)
            try payload.encode(delete, forKey: .payload)
        case .categorize(let categorize):
            try container.encode(InverseKind.categorize, forKey: .type)
            try payload.encode(categorize, forKey: .payload)
        case .payee(let payee):
            try container.encode(InverseKind.payee, forKey: .type)
            try payload.encode(payee, forKey: .payload)
        case .rule(let rule):
            try container.encode(InverseKind.rule, forKey: .type)
            try payload.encode(rule, forKey: .payload)
        case .account(let account):
            try container.encode(InverseKind.account, forKey: .type)
            try payload.encode(account, forKey: .payload)
        case .carryover(let carryover):
            try container.encode(InverseKind.carryover, forKey: .type)
            try payload.encode(carryover, forKey: .payload)
        case .learningPref(let learning):
            try container.encode(InverseKind.learningPref, forKey: .type)
            try payload.encode(learning, forKey: .payload)
        case .transactionMetadata(let metadata):
            try container.encode(InverseKind.transactionMetadata, forKey: .type)
            try payload.encode(metadata, forKey: .payload)
        }
    }
}
