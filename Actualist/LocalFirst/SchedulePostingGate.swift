import Foundation

@MainActor
final class SchedulePostingGate {
    struct Lease: Hashable, Sendable {
        fileprivate let budgetID: String
        fileprivate let scheduleID: String
        fileprivate let sessionGeneration: Int
        fileprivate let id: UUID
    }

    private struct Key: Hashable {
        let budgetID: String
        let scheduleID: String
        let sessionGeneration: Int
    }

    private var activeLeases: [Key: Lease] = [:]

    func acquire(budgetID: String, scheduleID: String, sessionGeneration: Int) throws -> Lease {
        let key = Key(budgetID: budgetID, scheduleID: scheduleID, sessionGeneration: sessionGeneration)
        guard activeLeases[key] == nil else { throw SchedulePostingError.alreadyInFlight }
        let lease = Lease(
            budgetID: budgetID,
            scheduleID: scheduleID,
            sessionGeneration: sessionGeneration,
            id: UUID()
        )
        activeLeases[key] = lease
        return lease
    }

    func release(_ lease: Lease) {
        let key = Key(
            budgetID: lease.budgetID,
            scheduleID: lease.scheduleID,
            sessionGeneration: lease.sessionGeneration
        )
        guard activeLeases[key] == lease else { return }
        activeLeases[key] = nil
    }

    func invalidate(sessionGeneration: Int) {
        let keys = activeLeases.compactMap { key, lease in
            lease.sessionGeneration == sessionGeneration ? key : nil
        }
        for key in keys { activeLeases[key] = nil }
    }
}
