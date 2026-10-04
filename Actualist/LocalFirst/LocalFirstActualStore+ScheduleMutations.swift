import Foundation

typealias ScheduleMutationHook = @MainActor @Sendable () async -> Void
typealias ScheduleMutationRefreshHook = @MainActor @Sendable () async throws -> Void

extension LocalFirstActualStore {
    func scheduleMutationSessionContext(
        budgetID: String
    ) throws -> ScheduleMutationSessionContext {
        _ = try requireDatabase(for: budgetID)
        return ScheduleMutationSessionContext(budgetID: budgetID, generation: budgetSessionGeneration)
    }

    func scheduleMutationReview(
        budgetID: String,
        scheduleID: String
    ) async throws -> ReviewedScheduleMutation {
        let context = try scheduleMutationSessionContext(budgetID: budgetID)
        let database = try requireDatabase(for: budgetID)
        let revision = try await database.scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID)
        try requireScheduleMutationSession(context, database: database)
        return ReviewedScheduleMutation(context: context, revision: revision)
    }

    func createSchedule(
        _ command: ScheduleCreateCommand,
        context: ScheduleMutationSessionContext
    ) async throws -> ScheduleMutationOutcome {
        try Task.checkCancellation()
        guard context.budgetID == command.budgetID else {
            throw ScheduleMutationCommandError.reviewChanged
        }
        let database = try requireDatabase(for: command.budgetID)
        try requireScheduleMutationSession(context, database: database)
        await scheduleMutationBeforeCommitHook?()
        try Task.checkCancellation()
        try requireScheduleMutationSession(context, database: database)
        let receipt: ScheduleMutationResult
        do {
            receipt = try await database.createSchedule(command)
        } catch LocalFirstError.budgetNotOpened {
            throw ScheduleMutationCommandError.reviewChanged
        }
        await scheduleMutationAfterCommitHook?()
        return await finishScheduleMutation(receipt, database: database, context: context)
    }

    func updateSchedule(
        review: ReviewedScheduleMutation,
        fields: ScheduleEditFields,
        asOfDayID: String,
        now: Date
    ) async throws -> ScheduleMutationOutcome {
        try await commitScheduleMutation(review: review) { database in
            try await database.updateSchedule(
                review: review.revision,
                fields: fields,
                asOfDayID: asOfDayID,
                now: now
            )
        }
    }

    func deleteSchedule(review: ReviewedScheduleMutation) async throws -> ScheduleMutationOutcome {
        try await commitScheduleMutation(review: review) { database in
            try await database.deleteSchedule(review: review.revision)
        }
    }

    func skipNextDate(
        review: ReviewedScheduleMutation,
        now: Date
    ) async throws -> ScheduleMutationOutcome {
        try await commitScheduleMutation(review: review) { database in
            try await database.skipNextDate(review: review.revision, now: now)
        }
    }

    func completeSchedule(review: ReviewedScheduleMutation) async throws -> ScheduleMutationOutcome {
        try await commitScheduleMutation(review: review) { database in
            try await database.completeSchedule(review: review.revision)
        }
    }

    private func commitScheduleMutation(
        review: ReviewedScheduleMutation,
        write: @escaping @MainActor (BudgetDatabase) async throws -> ScheduleMutationResult
    ) async throws -> ScheduleMutationOutcome {
        try Task.checkCancellation()
        let context = review.context
        let database = try requireDatabase(for: context.budgetID)
        try requireScheduleMutationSession(context, database: database)
        guard review.revision.budgetID == context.budgetID else {
            throw ScheduleMutationCommandError.reviewChanged
        }
        await scheduleMutationBeforeCommitHook?()
        try Task.checkCancellation()
        try requireScheduleMutationSession(context, database: database)
        let receipt: ScheduleMutationResult
        do {
            receipt = try await write(database)
        } catch LocalFirstError.budgetNotOpened {
            throw ScheduleMutationCommandError.reviewChanged
        }
        await scheduleMutationAfterCommitHook?()
        return await finishScheduleMutation(receipt, database: database, context: context)
    }

    private func requireScheduleMutationSession(
        _ context: ScheduleMutationSessionContext,
        database: BudgetDatabase
    ) throws {
        guard context.generation == budgetSessionGeneration else {
            throw ScheduleMutationCommandError.reviewChanged
        }
        try requireSyncSession(
            database: database,
            budgetID: context.budgetID,
            generation: context.generation
        )
    }

    private func finishScheduleMutation(
        _ receipt: ScheduleMutationResult,
        database: BudgetDatabase,
        context: ScheduleMutationSessionContext
    ) async -> ScheduleMutationOutcome {
        guard receipt.kind != .unchanged, receipt.appliedMessageCount > 0 else {
            return ScheduleMutationOutcome(receipt: receipt, refreshPending: false)
        }

        // This unstructured MainActor task owns publication after the database has
        // committed. Caller cancellation cannot erase or misreport that receipt.
        return await Task { @MainActor [self] in
            do {
                try requireScheduleMutationSession(context, database: database)
                invalidateScheduleCache(budgetID: context.budgetID)
                invalidateRulesCache(budgetID: context.budgetID)
                try await scheduleMutationBeforeRefreshHook?()
                try requireScheduleMutationSession(context, database: database)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .autoupdatingCurrent
                let today = ActualScheduleRecurrence.dayID(from: Date(), calendar: calendar)
                try await refreshSchedulesAfterWrite(budgetID: context.budgetID, asOf: today)
                try requireScheduleMutationSession(context, database: database)
                try await refreshRulesCache(database: database, budgetID: context.budgetID)
                try requireScheduleMutationSession(context, database: database)
                await schedulePendingLocalMessageFlush(database: database, budgetID: context.budgetID)
                return ScheduleMutationOutcome(receipt: receipt, refreshPending: false)
            } catch {
                if (try? requireScheduleMutationSession(context, database: database)) != nil {
                    await schedulePendingLocalMessageFlush(database: database, budgetID: context.budgetID)
                }
                return ScheduleMutationOutcome(receipt: receipt, refreshPending: true)
            }
        }.value
    }
}
