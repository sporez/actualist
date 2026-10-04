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

extension LocalFirstActualStore {
    func schedulePostingAvailability(budgetID: String) throws -> SchedulePostingAvailability {
        _ = try requireDatabase(for: budgetID)
        if isDemoBudgetActive {
            return SchedulePostingAvailability(
                canPost: false,
                reason: "Demo budgets cannot be remotely synced, so schedule posting is unavailable."
            )
        }
        guard let serverURLString = openedServerURLString,
              !serverURLString.isEmpty else {
            return SchedulePostingAvailability(
                canPost: false,
                reason: "Connect to an Actual server before posting a scheduled transaction."
            )
        }
        guard try keychain.readActualSyncToken() != nil else {
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
        let database = try requireDatabase(for: budgetID)
        let mutation = try await database.scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID)
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
        let lease = try schedulePostingGate.acquire(
            budgetID: session.budgetID,
            scheduleID: review.mutation.scheduleID,
            sessionGeneration: session.generation
        )
        defer { schedulePostingGate.release(lease) }
        let database = try requireDatabase(for: session.budgetID)
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
        guard let serverURLString = openedServerURLString else { throw SchedulePostingError.syncRequired }

        _ = try await pullAndReload(
            budgetID: session.budgetID,
            serverURLString: serverURLString,
            performsScheduleAdvancement: false
        )
        try requireSchedulePostingSession(session, database: database)

        let currentReview = try await database.scheduleMutationReview(
            budgetID: session.budgetID,
            scheduleID: review.mutation.scheduleID
        )
        try requireSchedulePostingSession(session, database: database)
        guard currentReview == review.mutation else {
            throw SchedulePostingError.reviewChanged
        }

        let today = ActualDateOnly.today()
        let loaded = try await database.fetchSchedules(budgetID: session.budgetID, today: today)
        try requireSchedulePostingSession(session, database: database)
        guard let detail = loaded.detail(id: review.mutation.scheduleID),
              detail.capabilities.canPost,
              [.due, .upcoming, .missed].contains(detail.status),
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
        guard let transactionDate = Self.schedulePostingDate(postedDayID) else {
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
            writeReceipt = try await database.postScheduleOccurrence(
                review: currentReview,
                draft: baseDraft,
                transactionID: transactionID,
                postedDayID: postedDayID,
                asOf: today
            )
        } catch ScheduleMutationCommandError.reviewChanged {
            throw SchedulePostingError.reviewChanged
        } catch ScheduleMutationCommandError.unsupportedCapability {
            throw SchedulePostingError.unsupportedSchedule
        } catch ScheduleMutationCommandError.unsupportedSchema {
            throw SchedulePostingError.unsupportedSchedule
        }
        await scheduleMutationAfterCommitHook?()
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
        guard session.generation == budgetSessionGeneration else {
            throw SchedulePostingError.reviewChanged
        }
        try requireSyncSession(database: database, budgetID: session.budgetID, generation: session.generation)
    }

    private func finishSchedulePosting(
        _ receipt: SchedulePostingWriteReceipt,
        database: BudgetDatabase,
        session: ScheduleMutationSessionContext
    ) async -> SchedulePostingReceipt {
        // The retained finisher owns publication after commit. Cancellation of
        // the caller cannot turn a durable post into an apparent failed write.
        let tail = await finishDurableCommit(
            database: database,
            budgetID: session.budgetID,
            requireSession: { [self] in try requireSchedulePostingSession(session, database: database) },
            reload: { [self] in
                invalidateScheduleCache(budgetID: session.budgetID)
                try await reloadAfterTransactionMutation(
                    database: database,
                    budgetID: session.budgetID,
                    accountIDs: receipt.affectedAccountIDs,
                    monthIDs: receipt.affectedMonthIDs
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

    private static func schedulePostingDate(_ dayID: String) -> Date? {
        guard ActualScheduleRecurrence.date(from: dayID) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let parts = dayID.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12
        ))
    }
}

extension LocalFirstActualStore: SchedulePostingRepositoryProtocol { }
