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
}

/// A user gesture as submitted, before live cells are read. The write path
/// turns this into a summary and inverse inside the commit transaction so a
/// concurrent Shortcuts write cannot race the before-values.
enum BudgetActionDescriptor: Equatable, Sendable {
    case assign(month: String, categoryID: String, budgeted: Int)
    case move(month: String, legs: [BudgetMoveLeg])
}

extension BudgetActionInverse: Codable {
    private enum InverseKind: String, Codable {
        case assign
        case move
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
        }
    }
}
