import Foundation

extension LocalFirstActualStore {
    /// Called after a successful remote pull. Does not pull, and does not throw
    /// a posting error back to that caller. Demo reloads must not call this.
    func advanceSchedulesAfterSuccessfulSync(
        budgetID: String,
        database: BudgetDatabase,
        generation: Int
    ) async {
        guard ownsScheduleAdvancementSession(database: database, budgetID: budgetID, generation: generation) else {
            return
        }
        if Task.isCancelled { return }
        let today = Self.scheduleAdvancementToday()
        let result: ScheduleAdvancementResult
        do {
            result = try await database.advanceSchedules(budgetID: budgetID, today: today)
        } catch {
            await refreshInterruptedScheduleAdvancement(
                database: database,
                budgetID: budgetID,
                generation: generation
            )
            return
        }
        guard ownsScheduleAdvancementSession(database: database, budgetID: budgetID, generation: generation) else {
            return
        }
        if !result.skippedForToday {
            scheduleAutoPostRefusals = result.refusals
        }
        await publishScheduleAdvancement(
            result,
            database: database,
            budgetID: budgetID,
            generation: generation,
            today: today
        )
    }

    private func ownsScheduleAdvancementSession(
        database: BudgetDatabase,
        budgetID: String,
        generation: Int
    ) -> Bool {
        generation == budgetSessionGeneration
            && self.database === database
            && openedBudgetID == budgetID
    }

    private func publishScheduleAdvancement(
        _ result: ScheduleAdvancementResult,
        database: BudgetDatabase,
        budgetID: String,
        generation: Int,
        today: String
    ) async {
        guard !result.receipts.isEmpty || result.scheduleMutated else { return }
        guard ownsScheduleAdvancementSession(database: database, budgetID: budgetID, generation: generation) else {
            return
        }
        do {
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            invalidateScheduleCache(budgetID: budgetID)
            if !result.receipts.isEmpty {
                try await reloadAfterTransactionMutation(
                    database: database,
                    budgetID: budgetID,
                    accountIDs: result.receipts.flatMap(\.affectedAccountIDs),
                    monthIDs: result.receipts.flatMap(\.affectedMonthIDs)
                )
            }
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            try await refreshSchedulesAfterWrite(budgetID: budgetID, asOf: today)
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        } catch {
            await refreshInterruptedScheduleAdvancement(
                database: database,
                budgetID: budgetID,
                generation: generation
            )
        }
    }

    private func refreshInterruptedScheduleAdvancement(
        database: BudgetDatabase,
        budgetID: String,
        generation: Int
    ) async {
        guard ownsScheduleAdvancementSession(database: database, budgetID: budgetID, generation: generation) else {
            return
        }
        invalidateScheduleCache(budgetID: budgetID)
        invalidateTransactionFeedCaches(budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    /// Same local day-id calendar manual posting uses. Not UTC midnight.
    private static func scheduleAdvancementToday(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return ActualScheduleRecurrence.dayID(from: now, calendar: calendar)
    }
}
