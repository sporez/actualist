import Foundation

struct ScheduleRequestIdentity: Sendable {
    struct Ticket: Hashable, Sendable {
        let sessionID: UUID
        let budgetID: String
        let revision: UInt64
    }

    private var sessionID = UUID()
    private var nextRevision: UInt64 = 0
    private var latestRevisionByBudget: [String: UInt64] = [:]

    mutating func begin(budgetID: String) -> Ticket {
        nextRevision &+= 1
        latestRevisionByBudget[budgetID] = nextRevision
        return Ticket(sessionID: sessionID, budgetID: budgetID, revision: nextRevision)
    }

    func accepts(_ ticket: Ticket) -> Bool {
        ticket.sessionID == sessionID
            && latestRevisionByBudget[ticket.budgetID] == ticket.revision
    }

    mutating func invalidate(budgetID: String) {
        nextRevision &+= 1
        latestRevisionByBudget[budgetID] = nextRevision
    }

    mutating func resetSession() {
        sessionID = UUID()
        nextRevision = 0
        latestRevisionByBudget = [:]
    }
}
