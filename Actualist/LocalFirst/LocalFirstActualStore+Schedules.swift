import Foundation

typealias ScheduleReadHook = @MainActor @Sendable (_ budgetID: String, _ today: String) async -> Void

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

extension LocalFirstActualStore {
    func cachedSchedules(budgetID: String) -> LoadedSchedules? {
        schedulesByBudget[budgetID]
    }

    func refreshSchedules(
        budgetID: String,
        asOf today: String
    ) async throws -> LoadedSchedules {
        try Task.checkCancellation()
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let ticket = scheduleRequestIdentity.begin(budgetID: budgetID)
        let loaded = try await database.fetchSchedules(budgetID: budgetID, today: today)
        await scheduleReadHook?(budgetID, today)
        try Task.checkCancellation()
        try requireSyncSession(
            database: database,
            budgetID: budgetID,
            generation: generation
        )
        guard scheduleRequestIdentity.accepts(ticket),
              loaded.budgetID == budgetID else {
            throw CancellationError()
        }
        schedulesByBudget[budgetID] = loaded
        return loaded
    }

    func invalidateScheduleCache(budgetID: String) {
        schedulesByBudget[budgetID] = nil
        scheduleRequestIdentity.invalidate(budgetID: budgetID)
    }
}
