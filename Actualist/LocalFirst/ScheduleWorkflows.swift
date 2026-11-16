import Foundation

/// Schedules on the store: reads and their cache, edits, posting, the
/// daily advancement after a sync, and Schedule this future transaction.
/// The store owns it; the schedule cache and auto-post refusals stay on the
/// store, which publishes them.
@MainActor
final class ScheduleWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore
    private var requestIdentity = ScheduleRequestIdentity()
    let postingGate = SchedulePostingGate()

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func resetRequestSession() { requestIdentity.resetSession() }

    func cachedSchedules(budgetID: String) -> LoadedSchedules? {
        store.schedulesByBudget[budgetID]
    }

    /// Read-through to the store's published refusals, which the protocol requires.
    var scheduleAutoPostRefusals: [ScheduleAutoPostRefusal] { store.scheduleAutoPostRefusals }

    func refreshSchedules(
        budgetID: String,
        asOf today: String
    ) async throws -> LoadedSchedules {
        try Task.checkCancellation()
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let ticket = requestIdentity.begin(budgetID: budgetID)
        let loaded = try await ScheduleSQL.fetchSchedules(budgetID: budgetID, today: today, in: database)
        // Refusals persist with the budget so a same-day relaunch, which skips
        // the once-a-day run, still shows them.
        let storedRefusals = (try? await SchedulePostingSQL.scheduleAutoPostRefusals(in: database)) ?? []
        #if DEBUG
        await store.testSeams?.scheduleReadHook?(budgetID, today)
        #endif
        try Task.checkCancellation()
        try store.requireSyncSession(
            database: database,
            budgetID: budgetID,
            generation: generation
        )
        guard requestIdentity.accepts(ticket),
              loaded.budgetID == budgetID else {
            throw CancellationError()
        }
        store.schedulesByBudget[budgetID] = loaded
        let retained = ScheduleAutoPostRefusalReconciler.retained(storedRefusals, in: loaded)
        store.scheduleAutoPostRefusals = retained
        let ended = storedRefusals.filter { !retained.contains($0) }
        if !ended.isEmpty {
            try? await SchedulePostingSQL.removeScheduleAutoPostRefusals(ended, in: database)
        }
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
        store.schedulesByBudget[budgetID] = nil
        requestIdentity.invalidate(budgetID: budgetID)
    }

    func scheduleMutationSessionContext(
        budgetID: String
    ) throws -> ScheduleMutationSessionContext {
        _ = try store.requireDatabase(for: budgetID)
        return ScheduleMutationSessionContext(budgetID: budgetID, generation: store.budgetSessionGeneration)
    }

    func scheduleMutationReview(
        budgetID: String,
        scheduleID: String
    ) async throws -> ReviewedScheduleMutation {
        let context = try scheduleMutationSessionContext(budgetID: budgetID)
        let database = try store.requireDatabase(for: budgetID)
        let revision = try await ScheduleReviewSQL.scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID, in: database)
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
        let database = try store.requireDatabase(for: command.budgetID)
        try requireScheduleMutationSession(context, database: database)
        #if DEBUG
        await store.testSeams?.scheduleMutationBeforeCommitHook?()
        #endif
        try Task.checkCancellation()
        try requireScheduleMutationSession(context, database: database)
        let receipt: ScheduleMutationResult
        do {
            receipt = try await ScheduleEditSQL.createSchedule(command, in: database)
        } catch LocalFirstError.budgetNotOpened {
            throw ScheduleMutationCommandError.reviewChanged
        }
        #if DEBUG
        await store.testSeams?.scheduleMutationAfterCommitHook?()
        #endif
        return await finishScheduleMutation(receipt, database: database, context: context)
    }

    func updateSchedule(
        review: ReviewedScheduleMutation,
        fields: ScheduleEditFields,
        asOfDayID: String,
        now: Date
    ) async throws -> ScheduleMutationOutcome {
        try await commitScheduleMutation(review: review) { database in
            try await ScheduleEditSQL.updateSchedule(
                review: review.revision,
                fields: fields,
                asOfDayID: asOfDayID,
                now: now,
                in: database
            )
        }
    }

    func deleteSchedule(review: ReviewedScheduleMutation) async throws -> ScheduleMutationOutcome {
        try await commitScheduleMutation(review: review) { database in
            try await ScheduleEditSQL.deleteSchedule(review: review.revision, in: database)
        }
    }

    func skipNextDate(
        review: ReviewedScheduleMutation,
        now: Date
    ) async throws -> ScheduleMutationOutcome {
        try await commitScheduleMutation(review: review) { database in
            try await ScheduleEditSQL.skipNextDate(review: review.revision, now: now, in: database)
        }
    }

    func completeSchedule(review: ReviewedScheduleMutation) async throws -> ScheduleMutationOutcome {
        try await commitScheduleMutation(review: review) { database in
            try await ScheduleEditSQL.completeSchedule(review: review.revision, in: database)
        }
    }

    private func commitScheduleMutation(
        review: ReviewedScheduleMutation,
        write: @escaping @MainActor (BudgetDatabase) async throws -> ScheduleMutationResult
    ) async throws -> ScheduleMutationOutcome {
        try Task.checkCancellation()
        let context = review.context
        let database = try store.requireDatabase(for: context.budgetID)
        try requireScheduleMutationSession(context, database: database)
        guard review.revision.budgetID == context.budgetID else {
            throw ScheduleMutationCommandError.reviewChanged
        }
        #if DEBUG
        await store.testSeams?.scheduleMutationBeforeCommitHook?()
        #endif
        try Task.checkCancellation()
        try requireScheduleMutationSession(context, database: database)
        let receipt: ScheduleMutationResult
        do {
            receipt = try await write(database)
        } catch LocalFirstError.budgetNotOpened {
            throw ScheduleMutationCommandError.reviewChanged
        }
        #if DEBUG
        await store.testSeams?.scheduleMutationAfterCommitHook?()
        #endif
        return await finishScheduleMutation(receipt, database: database, context: context)
    }

    private func requireScheduleMutationSession(
        _ context: ScheduleMutationSessionContext,
        database: BudgetDatabase
    ) throws {
        guard context.generation == store.budgetSessionGeneration else {
            throw ScheduleMutationCommandError.reviewChanged
        }
        try store.requireSyncSession(
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
        let tail = await store.finishDurableCommit(
            database: database,
            budgetID: context.budgetID,
            invalidatesFeedCachesOnFailure: false,
            requireSession: { [self] in try requireScheduleMutationSession(context, database: database) },
            reload: { [self] in
                invalidateScheduleCache(budgetID: context.budgetID)
                store.rules.invalidateRulesCache(budgetID: context.budgetID)
                #if DEBUG
                try await store.testSeams?.scheduleMutationBeforeRefreshHook?()
                #endif
                try requireScheduleMutationSession(context, database: database)
                try await refreshSchedulesAfterWrite(budgetID: context.budgetID, asOf: ActualDateOnly.today())
                try requireScheduleMutationSession(context, database: database)
                try await store.rules.refreshRulesCache(database: database, budgetID: context.budgetID)
            }
        )
        return ScheduleMutationOutcome(receipt: receipt, refreshPending: tail.refreshPending)
    }

    func schedulePostingAvailability(budgetID: String) throws -> SchedulePostingAvailability {
        _ = try store.requireDatabase(for: budgetID)
        if store.isDemoBudgetActive {
            return SchedulePostingAvailability(
                canPost: false,
                reason: "Demo budgets cannot be remotely synced, so schedule posting is unavailable."
            )
        }
        guard let serverURLString = store.openedServerURLString,
              !serverURLString.isEmpty else {
            return SchedulePostingAvailability(
                canPost: false,
                reason: "Connect to an Actual server before posting a scheduled transaction."
            )
        }
        guard try store.keychain.readActualSyncToken() != nil else {
            return SchedulePostingAvailability(
                canPost: false,
                reason: "Sign in and sync this budget before posting a scheduled transaction."
            )
        }
        return SchedulePostingAvailability(canPost: true, reason: nil)
    }

    func schedulePostingReview(
        budgetID: String,
        scheduleID: String
    ) async throws -> SchedulePostingReview {
        let session = try scheduleMutationSessionContext(budgetID: budgetID)
        let database = try store.requireDatabase(for: budgetID)
        let mutation = try await ScheduleReviewSQL.scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID, in: database)
        try requireSchedulePostingSession(session, database: database)
        return SchedulePostingReview(session: session, mutation: mutation)
    }

    func postSchedule(
        review: SchedulePostingReview,
        date: SchedulePostingDate,
        onPhaseChange: @escaping @MainActor @Sendable (SchedulePostingPhase) -> Void = { _ in }
    ) async throws -> SchedulePostingReceipt {
        try Task.checkCancellation()
        let session = review.session
        let lease = try postingGate.acquire(
            budgetID: session.budgetID,
            scheduleID: review.mutation.scheduleID,
            sessionGeneration: session.generation
        )
        defer { postingGate.release(lease) }
        let database = try store.requireDatabase(for: session.budgetID)
        try requireSchedulePostingSession(session, database: database)
        guard review.mutation.budgetID == session.budgetID else {
            throw SchedulePostingError.reviewChanged
        }
        // Demo mode's successful local reload is not a remote synchronization
        // and cannot satisfy the explicit sync-first posting contract.
        let availability = try schedulePostingAvailability(budgetID: session.budgetID)
        guard availability.canPost else {
            throw SchedulePostingError.syncRequired
        }
        guard let serverURLString = store.openedServerURLString else { throw SchedulePostingError.syncRequired }

        _ = try await store.pullAndReload(
            budgetID: session.budgetID,
            serverURLString: serverURLString,
            performsScheduleAdvancement: false
        )
        try requireSchedulePostingSession(session, database: database)

        let currentReview = try await ScheduleReviewSQL.scheduleMutationReview(
            budgetID: session.budgetID,
            scheduleID: review.mutation.scheduleID,
            in: database
        )
        try requireSchedulePostingSession(session, database: database)
        guard currentReview == review.mutation else {
            throw SchedulePostingError.reviewChanged
        }

        let today = ActualDateOnly.today()
        let loaded = try await ScheduleSQL.fetchSchedules(budgetID: session.budgetID, today: today, in: database)
        try requireSchedulePostingSession(session, database: database)
        guard let detail = loaded.detail(id: review.mutation.scheduleID),
              detail.capabilities.canPost,
              detail.status.allowsManualPosting,
              detail.account.availability == .available,
              let accountID = detail.account.id,
              let amount = detail.amount.postingAmount else {
            throw SchedulePostingError.occurrenceNoLongerPostable
        }
        let postedDayID: String
        switch date {
        case .scheduled:
            guard let scheduled = detail.effectiveNextDate else {
                throw SchedulePostingError.unsupportedSchedule
            }
            postedDayID = scheduled
        case .today(let selectedDayID):
            guard selectedDayID == today else { throw SchedulePostingError.reviewChanged }
            postedDayID = selectedDayID
        }
        guard let transactionDate = ActualDateOnly.noonDate(fromDayID: postedDayID) else {
            throw SchedulePostingError.unsupportedSchedule
        }

        let payeeID = detail.payee.postingPayeeID
        let baseDraft = TransactionDraft(
            accountID: accountID,
            date: transactionDate,
            amountMinorUnits: amount,
            payeeID: payeeID,
            payeeName: detail.payee.name ?? "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            scheduleID: detail.id
        )
        let transactionID = UUID().uuidString
        try requireSchedulePostingSession(session, database: database)
        try Task.checkCancellation()
        onPhaseChange(.submitting)
        let writeReceipt: SchedulePostingWriteReceipt
        do {
            writeReceipt = try await SchedulePostingSQL.postScheduleOccurrence(
                review: currentReview,
                draft: baseDraft,
                transactionID: transactionID,
                postedDayID: postedDayID,
                asOf: today,
                in: database
            )
        } catch ScheduleMutationCommandError.reviewChanged {
            throw SchedulePostingError.reviewChanged
        } catch ScheduleMutationCommandError.unsupportedCapability {
            throw SchedulePostingError.unsupportedSchedule
        } catch ScheduleMutationCommandError.unsupportedSchema {
            throw SchedulePostingError.unsupportedSchedule
        }
        #if DEBUG
        await store.testSeams?.scheduleMutationAfterCommitHook?()
        #endif
        return await finishSchedulePosting(
            writeReceipt,
            database: database,
            session: session
        )
    }

    private func requireSchedulePostingSession(
        _ session: ScheduleMutationSessionContext,
        database: BudgetDatabase
    ) throws {
        guard session.generation == store.budgetSessionGeneration else {
            throw SchedulePostingError.reviewChanged
        }
        try store.requireSyncSession(database: database, budgetID: session.budgetID, generation: session.generation)
    }

    private func finishSchedulePosting(
        _ receipt: SchedulePostingWriteReceipt,
        database: BudgetDatabase,
        session: ScheduleMutationSessionContext
    ) async -> SchedulePostingReceipt {
        // The retained finisher owns publication after commit. Cancellation of
        // the caller cannot turn a durable post into an apparent failed write.
        let tail = await store.finishDurableCommit(
            database: database,
            budgetID: session.budgetID,
            requireSession: { [self] in try requireSchedulePostingSession(session, database: database) },
            reload: { [self] in
                invalidateScheduleCache(budgetID: session.budgetID)
                try await store.reloadAfterTransactionMutation(
                    database: database,
                    budgetID: session.budgetID,
                    accountIDs: receipt.affectedAccountIDs
                )
                try requireSchedulePostingSession(session, database: database)
                try await refreshSchedulesAfterWrite(budgetID: session.budgetID, asOf: ActualDateOnly.today())
            }
        )
        let refreshPending = tail.refreshPending
        return SchedulePostingReceipt(
            scheduleID: receipt.scheduleID,
            transactionID: receipt.transactionID,
            occurrenceDayID: receipt.occurrenceDayID,
            postedDayID: receipt.postedDayID,
            appliedMessageCount: receipt.appliedMessageCount,
            refreshPending: refreshPending
        )
    }

    func scheduleConversionSessionContext(budgetID: String) throws -> ScheduleMutationSessionContext {
        _ = try store.requireDatabase(for: budgetID)
        return ScheduleMutationSessionContext(budgetID: budgetID, generation: store.budgetSessionGeneration)
    }

    func scheduleConversionReview(
        budgetID: String,
        transactionID: String,
        asOfDayID: String
    ) async throws -> ScheduleConversionReview {
        let context = try scheduleConversionSessionContext(budgetID: budgetID)
        let database = try store.requireDatabase(for: budgetID)
        let review = try await ScheduleConversionSQL.scheduleConversionReview(
            context: context,
            transactionID: transactionID,
            asOfDayID: asOfDayID,
            identity: .make(),
            in: database
        )
        try requireScheduleConversionSession(context, database: database)
        return review
    }

    func convertFutureTransaction(
        review: ScheduleConversionReview
    ) async throws -> ScheduleConversionReceipt {
        try Task.checkCancellation()
        let context = review.context
        let database = try store.requireDatabase(for: context.budgetID)
        try requireScheduleConversionSession(context, database: database)
        #if DEBUG
        await store.testSeams?.scheduleMutationBeforeCommitHook?()
        #endif
        try Task.checkCancellation()
        try requireScheduleConversionSession(context, database: database)

        let committed: ScheduleConversionWriteReceipt
        do {
            committed = try await ScheduleConversionSQL.convertFutureTransaction(review: review, in: database)
        } catch LocalFirstError.budgetNotOpened {
            throw ScheduleConversionError.reviewChanged
        } catch ScheduleMutationCommandError.identityConflict {
            throw ScheduleConversionError.identityConflict
        }
        #if DEBUG
        await store.testSeams?.scheduleMutationAfterCommitHook?()
        #endif
        return await finishScheduleConversion(committed, database: database, context: context)
    }

    private func requireScheduleConversionSession(
        _ context: ScheduleMutationSessionContext,
        database: BudgetDatabase
    ) throws {
        guard context.generation == store.budgetSessionGeneration else {
            throw ScheduleConversionError.reviewChanged
        }
        try store.requireSyncSession(database: database, budgetID: context.budgetID, generation: context.generation)
    }

    private func finishScheduleConversion(
        _ committed: ScheduleConversionWriteReceipt,
        database: BudgetDatabase,
        context: ScheduleMutationSessionContext
    ) async -> ScheduleConversionReceipt {
        let tail = await store.finishDurableCommit(
            database: database,
            budgetID: context.budgetID,
            requireSession: { [self] in try requireScheduleConversionSession(context, database: database) },
            reload: { [self] in
                invalidateScheduleCache(budgetID: context.budgetID)
                store.rules.invalidateRulesCache(budgetID: context.budgetID)
                try await store.reloadAfterTransactionMutation(
                    database: database,
                    budgetID: context.budgetID,
                    accountIDs: [committed.sourceAccountID]
                )
                try requireScheduleConversionSession(context, database: database)
                #if DEBUG
                try await store.testSeams?.scheduleMutationBeforeRefreshHook?()
                #endif
                try requireScheduleConversionSession(context, database: database)
                try await refreshSchedulesAfterWrite(
                    budgetID: context.budgetID,
                    asOf: ActualDateOnly.today()
                )
                try requireScheduleConversionSession(context, database: database)
                try await store.rules.refreshRulesCache(database: database, budgetID: context.budgetID)
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

    /// Called after a remote pull, and from its failure path (not for
    /// cancellation or a changed session). A failed sync passes
    /// `syncSucceeded: false`: schedules still advance but nothing is posted
    /// (Actual's `advanceSchedulesService(false)`). Does not pull, and does not
    /// throw to that caller. Demo reloads must not call this.
    func advanceSchedulesAfterSync(
        budgetID: String,
        database: BudgetDatabase,
        generation: Int,
        syncSucceeded: Bool = true
    ) async {
        guard ownsScheduleAdvancementSession(database: database, budgetID: budgetID, generation: generation) else {
            return
        }
        if Task.isCancelled { return }
        let today = ActualDateOnly.today()
        let result: ScheduleAdvancementResult
        do {
            result = try await SchedulePostingSQL.advanceSchedules(
                budgetID: budgetID, today: today, postingAllowed: syncSucceeded,
                in: database
            )
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
        if result.refusalsReplaced {
            store.scheduleAutoPostRefusals = result.refusals
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
        generation == store.budgetSessionGeneration
            && store.database === database
            && store.openedBudgetID == budgetID
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
            try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            invalidateScheduleCache(budgetID: budgetID)
            if !result.receipts.isEmpty {
                try await store.reloadAfterTransactionMutation(
                    database: database,
                    budgetID: budgetID,
                    accountIDs: result.receipts.flatMap(\.affectedAccountIDs)
                )
            }
            try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            try await refreshSchedulesAfterWrite(budgetID: budgetID, asOf: today)
            try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            await store.schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
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
        store.invalidateTransactionFeedCaches(budgetID: budgetID)
        await store.schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

}

extension ScheduleWorkflows:
    ScheduleRepositoryProtocol,
    ScheduleMutationRepositoryProtocol,
    SchedulePostingRepositoryProtocol,
    TransactionScheduleConversionRepositoryProtocol { }
