import Foundation

extension LocalFirstActualStore {
    func scheduleConversionSessionContext(budgetID: String) throws -> ScheduleConversionSessionContext {
        _ = try requireDatabase(for: budgetID)
        return ScheduleConversionSessionContext(budgetID: budgetID, generation: budgetSessionGeneration)
    }

    func scheduleConversionReview(
        budgetID: String,
        transactionID: String,
        asOfDayID: String
    ) async throws -> ScheduleConversionReview {
        let context = try scheduleConversionSessionContext(budgetID: budgetID)
        let database = try requireDatabase(for: budgetID)
        let review = try await database.scheduleConversionReview(
            context: context,
            transactionID: transactionID,
            asOfDayID: asOfDayID,
            identity: .make()
        )
        try requireScheduleConversionSession(context, database: database)
        return review
    }

    func convertFutureTransaction(
        review: ScheduleConversionReview
    ) async throws -> ScheduleConversionReceipt {
        try Task.checkCancellation()
        let context = review.context
        let database = try requireDatabase(for: context.budgetID)
        try requireScheduleConversionSession(context, database: database)
        await scheduleMutationBeforeCommitHook?()
        try Task.checkCancellation()
        try requireScheduleConversionSession(context, database: database)

        let committed: ScheduleConversionWriteReceipt
        do {
            committed = try await database.convertFutureTransaction(review: review)
        } catch LocalFirstError.budgetNotOpened {
            throw ScheduleConversionError.reviewChanged
        } catch ScheduleMutationCommandError.identityConflict {
            throw ScheduleConversionError.identityConflict
        }
        await scheduleMutationAfterCommitHook?()
        return await finishScheduleConversion(committed, database: database, context: context)
    }

    private func requireScheduleConversionSession(
        _ context: ScheduleConversionSessionContext,
        database: BudgetDatabase
    ) throws {
        guard context.generation == budgetSessionGeneration else {
            throw ScheduleConversionError.reviewChanged
        }
        try requireSyncSession(database: database, budgetID: context.budgetID, generation: context.generation)
    }

    private func finishScheduleConversion(
        _ committed: ScheduleConversionWriteReceipt,
        database: BudgetDatabase,
        context: ScheduleConversionSessionContext
    ) async -> ScheduleConversionReceipt {
        let tail = await finishDurableCommit(
            database: database,
            budgetID: context.budgetID,
            requireSession: { [self] in try requireScheduleConversionSession(context, database: database) },
            reload: { [self] in
                invalidateScheduleCache(budgetID: context.budgetID)
                invalidateRulesCache(budgetID: context.budgetID)
                try await reloadAfterTransactionMutation(
                    database: database,
                    budgetID: context.budgetID,
                    accountIDs: [committed.sourceAccountID],
                    monthIDs: [committed.sourceMonthID]
                )
                try requireScheduleConversionSession(context, database: database)
                try await scheduleMutationBeforeRefreshHook?()
                try requireScheduleConversionSession(context, database: database)
                try await refreshSchedulesAfterWrite(
                    budgetID: context.budgetID,
                    asOf: Self.scheduleConversionToday()
                )
                try requireScheduleConversionSession(context, database: database)
                try await refreshRulesCache(database: database, budgetID: context.budgetID)
            }
        )
        let refreshPending = tail.refreshPending
        return ScheduleConversionReceipt(
            scheduleID: committed.scheduleID,
            sourceTransactionIDs: committed.sourceTransactionIDs,
            appliedMessageCount: committed.appliedMessageCount,
            refreshPending: refreshPending
        )
    }

    private static func scheduleConversionToday(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return ActualScheduleRecurrence.dayID(from: now, calendar: calendar)
    }
}

extension LocalFirstActualStore: TransactionScheduleConversionRepositoryProtocol { }
