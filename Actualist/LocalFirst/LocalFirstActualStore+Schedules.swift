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
        #if DEBUG
        await testSeams?.scheduleReadHook?(budgetID, today)
        #endif
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

    /// Refresh used after a committed write. A newer schedules read (or an
    /// invalidation) supersedes this one with `CancellationError`, which leaves
    /// current data and is not a failed refresh. Any other failure still throws.
    func refreshSchedulesAfterWrite(budgetID: String, asOf today: String) async throws {
        do {
            _ = try await refreshSchedules(budgetID: budgetID, asOf: today)
        } catch is CancellationError where !Task.isCancelled {
            return
        }
    }

    func invalidateScheduleCache(budgetID: String) {
        schedulesByBudget[budgetID] = nil
        scheduleRequestIdentity.invalidate(budgetID: budgetID)
    }
}
