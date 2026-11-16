import Foundation
import GRDB

struct SchedulePostingWriteReceipt: Hashable, Sendable {
    let scheduleID: String
    let transactionID: String
    let occurrenceDayID: String
    let postedDayID: String
    let appliedMessageCount: Int
    let affectedAccountIDs: [String]
    let affectedTransactionIDs: [String]
    let affectedMonthIDs: [String]
}

/// One schedule whose automatic post was deterministically refused.
struct ScheduleAutoPostRefusal: Hashable, Sendable {
    let scheduleID: String
    let scheduleName: String?
    /// The occurrence day that was refused; a later run or edit moves past it.
    let occurrenceDayID: String
    let refusal: SchedulePostingRefusal
}

struct ScheduleAdvancementResult: Sendable {
    let receipts: [SchedulePostingWriteReceipt]
    let scheduleMutated: Bool
    var refusals: [ScheduleAutoPostRefusal] = []
    /// A finished posting run replaced the persisted refusal set with `refusals`.
    /// Interrupted and non-posting runs leave the earlier set untouched.
    var refusalsReplaced = false
    /// The day marker already matched, so nothing ran and refusals are unknown.
    var skippedForToday = false
}

enum SchedulePostingSQL {
    static func postScheduleOccurrence(
        review: ScheduleMutationReview,
        draft: TransactionDraft,
        transactionID: String,
        postedDayID: String,
        asOf today: String,
        source: BudgetActionSource = .ui,
        now: Date = Date(),
        in database: isolated BudgetDatabase
    ) throws -> SchedulePostingWriteReceipt {
        guard !transactionID.isEmpty,
              draft.scheduleID == review.scheduleID,
              ActualScheduleRecurrence.date(from: postedDayID) != nil,
              ActualScheduleRecurrence.date(from: today) != nil else {
            throw SchedulePostingRefusal.invalidCommand
        }
        try Task.checkCancellation()
        let committed = try database.commitLocalPlan(now: now) { db in
            // Schema gaps (a missing table or column) and deleted or closed
            // referenced rows are deterministic per schedule, so they are
            // refusals rather than errors that would stop automatic advancement
            // on every sync.
            // I/O and cancellation propagate unchanged.
            do {
                return try schedulePostingPlan(
                    review: review, draft: draft, transactionID: transactionID,
                    postedDayID: postedDayID, today: today, source: source, now: now, in: database, db: db
                )
            } catch LocalFirstError.schemaUnavailable {
                throw SchedulePostingRefusal.unsupportedBudgetSchema
            } catch LocalFirstError.referencedRowUnavailable {
                throw SchedulePostingRefusal.referencedRowUnavailable
            }
        }
        let planned = committed.outcome
        return SchedulePostingWriteReceipt(
            scheduleID: planned.scheduleID,
            transactionID: planned.transactionID,
            occurrenceDayID: planned.occurrenceDayID,
            postedDayID: planned.postedDayID,
            appliedMessageCount: committed.appliedCount,
            affectedAccountIDs: planned.affectedAccountIDs,
            affectedTransactionIDs: planned.affectedTransactionIDs,
            affectedMonthIDs: planned.affectedMonthIDs
        )
    }

    private static func schedulePostingPlan(
        review: ScheduleMutationReview,
        draft: TransactionDraft,
        transactionID: String,
        postedDayID: String,
        today: String,
        source: BudgetActionSource,
        now: Date,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetDatabase.LocalCommitPlan<SchedulePostingWriteReceipt> {
        let current = try ScheduleReviewSQL.validateScheduleMutationReview(review, in: database, db: db)
        guard let accountID = current.projection.accountID,
              let accountColumns = try? database.columnSet(for: "accounts", db: db),
              accountColumns.contains("id") else {
            throw SchedulePostingRefusal.accountUnavailable
        }
        let closed = database.column("closed", fallback: "0", columns: accountColumns)
        let tombstone = database.column("tombstone", fallback: "0", columns: accountColumns)
        guard let accountRow = try Row.fetchOne(
            db,
            sql: "SELECT \(closed) AS closed, \(tombstone) AS tombstone FROM accounts WHERE id = ? LIMIT 1",
            arguments: [accountID]
        ), !SQLiteValueCoercion.lenientBool(accountRow["closed"]), !SQLiteValueCoercion.lenientBool(accountRow["tombstone"]) else {
            throw SchedulePostingRefusal.accountUnavailable
        }

        guard let schedule = try ScheduleSQL.fetchScheduleDetail(
            budgetID: review.budgetID,
            scheduleID: review.scheduleID,
            today: today,
            in: database,
            db: db
        ),
              schedule.capabilities.canPost,
              schedule.status.allowsManualPosting,
              schedule.account.availability == .available,
              current.projection.amount.postingAmount != nil,
              current.review.schedule.completed == false,
              !current.review.schedule.tombstone,
              !current.review.rule.tombstone else {
            throw SchedulePostingRefusal.occurrenceUnavailable
        }
        let expectedDay: String
        if postedDayID == today {
            expectedDay = today
        } else {
            guard let effectiveDate = current.effectiveNextDate,
                  postedDayID == effectiveDate else {
                throw SchedulePostingRefusal.occurrenceDateMismatch
            }
            expectedDay = effectiveDate
        }
        guard ActualScheduleRecurrence.date(from: expectedDay) != nil else {
            throw SchedulePostingRefusal.occurrenceUnavailable
        }
        guard try BudgetDatabase.actualDateValue(draft.date) == Int(PackedDate.compact(expectedDay)),
              draft.scheduleID == review.scheduleID else {
            throw SchedulePostingRefusal.draftMismatch
        }
        let initialTransfer = try draft.payeeID.map {
            try database.transferAccountID(ifPayee: $0, db: db) != nil
        } ?? false
        let ruleInputDraft = schedulePostingDraft(draft, isTransfer: initialTransfer)
        let evaluated = try RulePreviewSQL.previewRules(for: ruleInputDraft, in: database, db: db)
        guard !evaluated.deletesTransaction else {
            throw SchedulePostingRefusal.ruleDeletesTransaction
        }
        let projected = TransactionRulePreviewProjection.applying(evaluated, to: ruleInputDraft)
        let finalTransfer = try projected.payeeID.map {
            try database.transferAccountID(ifPayee: $0, db: db) != nil
        } ?? false
        let finalPayeeName = try RulePreviewSQL.rulePayeeName(for: projected.payeeID, in: database, db: db) ?? projected.payeeName
        let finalDraft = schedulePostingDraft(
            projected,
            isTransfer: finalTransfer,
            payeeName: finalPayeeName,
            // Actual's scheduled post sets sort_order to the clock in milliseconds. Transfer and
            // split posts keep their own writers' ordering.
            sortOrder: finalTransfer || !projected.splits.isEmpty
                ? nil
                : projected.sortOrder ?? now.timeIntervalSince1970 * 1_000
        )
        let trimmedName = finalDraft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        var builderForPlan = LocalFirstSyncMessageBuilder()
        let graph = try database.schedulePostingTransactionGraph(
            draft: finalDraft,
            transactionID: transactionID,
            builder: &builderForPlan,
            db: db
        )
        guard graph.primaryScheduleID == review.scheduleID else {
            throw SchedulePostingRefusal.ruleChangedScheduleLink
        }
        guard let occurrenceDate = schedule.effectiveNextDate else {
            throw SchedulePostingRefusal.occurrenceUnavailable
        }
        // Like Actual's "Post transaction today", a transaction dated before the
        // occurrence's match window is created anyway. It is linked to the
        // schedule but leaves the occurrence unpaid.
        let descriptor = CreateTransactionDescriptor(
            month: YearMonth(date: finalDraft.date).rawValue,
            amount: finalDraft.amountMinorUnits,
            payeeName: trimmedName.isEmpty ? nil : trimmedName,
            categoryID: finalDraft.categoryID,
            primaryTransactionID: transactionID,
            transactionIDs: graph.write.affectedTransactionIDs,
            graph: graph.graph,
            createdPayeeID: nil
        )
        let receipt = SchedulePostingWriteReceipt(
            scheduleID: review.scheduleID,
            transactionID: transactionID,
            occurrenceDayID: occurrenceDate,
            postedDayID: ActualDateOnly.dayID(from: finalDraft.date, timeZone: .autoupdatingCurrent),
            appliedMessageCount: 0,
            affectedAccountIDs: graph.write.affectedAccountIDs,
            affectedTransactionIDs: graph.write.affectedTransactionIDs,
            affectedMonthIDs: [YearMonth(date: finalDraft.date).rawValue]
        )
        return BudgetDatabase.LocalCommitPlan(
            drafts: graph.write.messages,
            action: ActionLogCommit(
                descriptor: .createTransaction(descriptor),
                source: source,
                actionID: transactionID,
                // An automatic post is not a user categorization, so it teaches nothing.
                learningTransactionIDs: source != .automatic
                    && !finalDraft.isTransfer && !finalDraft.isSplit && finalDraft.categoryID != nil
                    ? [transactionID]
                    : []
            ),
            outcome: receipt
        )
    }

    private static func schedulePostingDraft(
        _ draft: TransactionDraft,
        isTransfer: Bool,
        payeeName: String? = nil,
        sortOrder: Double? = nil
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: draft.accountID,
            date: draft.date,
            amountMinorUnits: draft.amountMinorUnits,
            payeeID: draft.payeeID,
            payeeName: payeeName ?? draft.payeeName,
            categoryID: draft.categoryID,
            notes: draft.notes,
            cleared: draft.cleared,
            isTransfer: isTransfer,
            importedPayee: draft.importedPayee,
            importedID: draft.importedID,
            sortOrder: sortOrder ?? draft.sortOrder,
            reconciled: draft.reconciled,
            isParent: draft.isParent,
            splits: draft.splits,
            scheduleID: draft.scheduleID
        )
    }

    /// Posts due or missed automatic schedules and advances paid occurrences.
    /// `metadata.json` `lastScheduleRun` is local, like Actual's metadata marker,
    /// and is patched with JSONSerialization so unknown keys survive. It is
    /// written when the run finishes. A typed `SchedulePostingRefusal` skips only
    /// that schedule and the day is still marked done (Actual sets
    /// `lastScheduleRun` after any successful sync and never retries a refusal
    /// the same day). Cancellation and any other error stop the run with the
    /// marker unset, so the next sync retries.
    ///
    /// `postingAllowed` is false after a failed or unauthorized sync. Like Actual
    /// (`advanceSchedulesService(false)`), a due or missed occurrence is then not
    /// posted and that schedule's loop ends, while paid occurrences still advance
    /// and past paid one-time schedules still complete. The run neither writes
    /// the day marker nor replaces the persisted refusals, so the next
    /// successful sync still posts today.
    static func advanceSchedules(
        budgetID: String,
        today: String,
        postingAllowed: Bool = true,
        now: Date = Date(),
        in database: isolated BudgetDatabase
    ) throws -> ScheduleAdvancementResult {
        if scheduleAdvancementDayMarker(in: database) == today {
            return ScheduleAdvancementResult(receipts: [], scheduleMutated: false, skippedForToday: true)
        }

        var receipts: [SchedulePostingWriteReceipt] = []
        var refusals: [ScheduleAutoPostRefusal] = []
        var scheduleMutated = false
        let ordered = schedulesInAdvancementOrder(
            Array(try ScheduleSQL.fetchSchedules(budgetID: budgetID, today: today, in: database).detailsByID.values)
        )
        for detail in ordered {
            if Task.isCancelled {
                return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
            }
            let step: ScheduleAdvancementStep
            do {
                step = try advanceSchedule(
                    detail.id,
                    budgetID: budgetID,
                    today: today,
                    now: now,
                    postingAllowed: postingAllowed,
                    receipts: &receipts,
                    refusals: &refusals,
                    scheduleMutated: &scheduleMutated,
                    in: database
                )
            } catch is CancellationError {
                return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
            }
            if step == .stopRun {
                return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
            }
        }

        if Task.isCancelled || !postingAllowed {
            return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
        }
        // A marker write failure must not hide committed posts. Leaving the
        // marker unset makes the next successful sync retry. The refusals are
        // stored first so a marked day never lacks its refusal set.
        do {
            try replaceScheduleAutoPostRefusals(refusals, in: database)
            try writeScheduleAdvancementDayMarker(today, in: database)
        } catch {
            return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
        }
        return ScheduleAdvancementResult(
            receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals, refusalsReplaced: true
        )
    }

    static func scheduleAutoPostRefusals(in database: isolated BudgetDatabase) throws -> [ScheduleAutoPostRefusal] {
        try database.queue.read { db in try ScheduleAutoPostRefusalTable.read(db) }
    }

    static func removeScheduleAutoPostRefusals(_ refusals: [ScheduleAutoPostRefusal], in database: isolated BudgetDatabase) throws {
        guard !refusals.isEmpty else { return }
        try database.queue.write { db in try ScheduleAutoPostRefusalTable.remove(refusals, db) }
    }

    private static func replaceScheduleAutoPostRefusals(_ refusals: [ScheduleAutoPostRefusal], in database: isolated BudgetDatabase) throws {
        try database.queue.write { db in try ScheduleAutoPostRefusalTable.replace(with: refusals, db) }
    }

    private enum ScheduleAdvancementStep {
        case nextSchedule
        case stopRun
    }

    private static let maximumOccurrencesPerSchedule = 366
    private static let dayMarkerKey = "lastScheduleRun"

    private static func advanceSchedule(
        _ scheduleID: String,
        budgetID: String,
        today: String,
        now: Date,
        postingAllowed: Bool,
        receipts: inout [SchedulePostingWriteReceipt],
        refusals: inout [ScheduleAutoPostRefusal],
        scheduleMutated: inout Bool,
        in database: isolated BudgetDatabase
    ) throws -> ScheduleAdvancementStep {
        for _ in 0..<Self.maximumOccurrencesPerSchedule {
            try Task.checkCancellation()
            guard let detail = try ScheduleSQL.fetchScheduleDetail(budgetID: budgetID, scheduleID: scheduleID, today: today, in: database) else {
                return .nextSchedule
            }
            let action = ScheduleOccurrencePlanner.action(
                postsTransaction: detail.postsTransaction,
                isRecurring: detail.dateRule.recurrence != nil,
                nextDate: detail.effectiveNextDate ?? "",
                status: detail.status,
                accountAvailable: detail.account.availability == .available,
                today: today
            )
            switch action {
            case .stop:
                return .nextSchedule
            case .postScheduledDate:
                // Actual records `failedToPost` and leaves this schedule.
                guard postingAllowed else { return .nextSchedule }
                let statusBefore = detail.status
                let isRecurring = detail.dateRule.recurrence != nil
                do {
                    receipts.append(try postScheduledOccurrence(
                        detail,
                        budgetID: budgetID,
                        today: today,
                        now: now,
                        in: database
                    ))
                } catch let refusal as SchedulePostingRefusal {
                    refusals.append(ScheduleAutoPostRefusal(
                        scheduleID: scheduleID, scheduleName: detail.name,
                        occurrenceDayID: detail.effectiveNextDate ?? "", refusal: refusal
                    ))
                    return .nextSchedule
                } catch is ScheduleMutationCommandError {
                    // Review preconditions (shared rule, missing schema, changed
                    // review) are typed and deterministic per schedule.
                    refusals.append(ScheduleAutoPostRefusal(
                        scheduleID: scheduleID, scheduleName: detail.name,
                        occurrenceDayID: detail.effectiveNextDate ?? "", refusal: .unsupportedOccurrence
                    ))
                    return .nextSchedule
                } catch {
                    return .stopRun
                }
                // A due post, and any one-time post, ends this schedule. Do not
                // complete a one-time schedule in the same run as its post.
                if statusBefore == .due || !isRecurring {
                    return .nextSchedule
                }
                let moved = try advanceRecurringOccurrence(
                    scheduleID,
                    budgetID: budgetID,
                    today: today,
                    now: now,
                    scheduleMutated: &scheduleMutated,
                    in: database
                )
                if moved == .stopRun || moved == .dateUnchanged {
                    return moved == .stopRun ? .stopRun : .nextSchedule
                }
            case .advanceRecurring:
                let moved = try advanceRecurringOccurrence(
                    scheduleID,
                    budgetID: budgetID,
                    today: today,
                    now: now,
                    scheduleMutated: &scheduleMutated,
                    in: database
                )
                if moved != .dateChanged {
                    return moved == .stopRun ? .stopRun : .nextSchedule
                }
            case .recomputeRecurring:
                let moved = try advanceRecurringOccurrence(
                    scheduleID,
                    budgetID: budgetID,
                    today: today,
                    now: now,
                    fromToday: true,
                    scheduleMutated: &scheduleMutated,
                    in: database
                )
                return moved == .stopRun ? .stopRun : .nextSchedule
            case .completeOneTime:
                do {
                    let result = try ScheduleEditSQL.completeSchedule(
                        review: ScheduleReviewSQL.scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID, in: database),
                        now: now,
                        in: database
                    )
                    if result.kind != .unchanged {
                        scheduleMutated = true
                    }
                } catch is CancellationError {
                    return .stopRun
                } catch {
                    return .nextSchedule
                }
                return .nextSchedule
            }
        }
        return .nextSchedule
    }

    private enum RecurringAdvanceStep {
        case dateChanged
        case dateUnchanged
        case stopRun
    }

    private static func postScheduledOccurrence(
        _ detail: ScheduleDetail,
        budgetID: String,
        today: String,
        now: Date,
        in database: isolated BudgetDatabase
    ) throws -> SchedulePostingWriteReceipt {
        guard let accountID = detail.account.id,
              let amount = detail.amount.postingAmount,
              let postedDayID = detail.effectiveNextDate,
              let transactionDate = ActualDateOnly.noonDate(fromDayID: postedDayID) else {
            throw SchedulePostingRefusal.unsupportedOccurrence
        }
        let draft = TransactionDraft(
            accountID: accountID,
            date: transactionDate,
            amountMinorUnits: amount,
            payeeID: detail.payee.postingPayeeID,
            payeeName: detail.payee.name ?? "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            scheduleID: detail.id
        )
        return try postScheduleOccurrence(
            review: ScheduleReviewSQL.scheduleMutationReview(budgetID: budgetID, scheduleID: detail.id, in: database),
            draft: draft,
            transactionID: UUID().uuidString,
            postedDayID: postedDayID,
            asOf: today,
            source: .automatic,
            now: now,
            in: database
        )
    }

    /// Moves a recurring next date to the next date after the current one, like user skip, or
    /// (`fromToday`) to the first date from today.
    private static func advanceRecurringOccurrence(
        _ scheduleID: String,
        budgetID: String,
        today: String,
        now: Date,
        fromToday: Bool = false,
        scheduleMutated: inout Bool,
        in database: isolated BudgetDatabase
    ) throws -> RecurringAdvanceStep {
        try Task.checkCancellation()
        guard let detail = try ScheduleSQL.fetchScheduleDetail(budgetID: budgetID, scheduleID: scheduleID, today: today, in: database),
              let currentDayID = detail.effectiveNextDate,
              detail.dateRule.recurrence != nil else {
            return .dateUnchanged
        }
        let review: ScheduleMutationReview
        do {
            review = try ScheduleReviewSQL.scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID, in: database)
        } catch is CancellationError {
            return .stopRun
        } catch {
            return .dateUnchanged
        }
        let committed: (outcome: Bool, appliedCount: Int)
        do {
            committed = try database.commitLocalPlan(now: now) { db in
                let current = try ScheduleReviewSQL.validateScheduleMutationReview(review, in: database, db: db)
                guard let recurrence = current.projection.dateRule.recurrence,
                      let effective = current.effectiveNextDate,
                      let next = current.review.uniqueNextDate,
                      let advanced = try (fromToday
                          ? ScheduleRuleMutation.initialNextDate(for: current.projection.dateRule, asOf: today)
                          : recurrence.nextDateAfter(effective)),
                      advanced != effective else {
                    return BudgetDatabase.LocalCommitPlan(drafts: [], action: nil, outcome: false)
                }
                var builder = LocalFirstSyncMessageBuilder()
                let messages = try localNextDateMessages(
                    rowID: next.id,
                    date: advanced,
                    baseTimestamp: next.baseTimestamp,
                    builder: &builder
                )
                return BudgetDatabase.LocalCommitPlan(drafts: messages, action: nil, outcome: true)
            }
        } catch is CancellationError {
            return .stopRun
        } catch {
            return .dateUnchanged
        }
        if committed.appliedCount > 0 {
            scheduleMutated = true
        }
        guard committed.outcome,
              let updated = try ScheduleSQL.fetchScheduleDetail(budgetID: budgetID, scheduleID: scheduleID, today: today, in: database)?.effectiveNextDate,
              updated != currentDayID else {
            return .dateUnchanged
        }
        return .dateChanged
    }

    /// Same local next-date messages the skip writer enqueues (`base: false`).
    private static func localNextDateMessages(
        rowID: String,
        date: String,
        baseTimestamp: String?,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard let baseTimestamp = baseTimestamp.flatMap(Int64.init) else {
            throw ScheduleMutationCommandError.unsupportedCapability(
                "The schedule's base date cannot be updated safely."
            )
        }
        return [
            try builder.makeMessage(
                dataset: "schedules_next_date",
                row: rowID,
                column: "local_next_date",
                value: ScheduleEditSQL.scheduleDateValue(date)
            ),
            try builder.makeMessage(
                dataset: "schedules_next_date",
                row: rowID,
                column: "local_next_date_ts",
                value: .int(baseTimestamp)
            )
        ]
    }

    private static func schedulesInAdvancementOrder(_ details: [ScheduleDetail]) -> [ScheduleDetail] {
        details.sorted { lhs, rhs in
            switch (lhs.effectiveNextDate, rhs.effectiveNextDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    private static func scheduleAdvancementMetadataURL(in database: isolated BudgetDatabase) -> URL {
        database.databaseURL.deletingLastPathComponent().appending(path: "metadata.json")
    }

    private static func scheduleAdvancementDayMarker(in database: isolated BudgetDatabase) -> String? {
        let url = scheduleAdvancementMetadataURL(in: database)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marker = object[Self.dayMarkerKey] as? String,
              !marker.isEmpty else {
            return nil
        }
        return marker
    }

    private static func writeScheduleAdvancementDayMarker(_ dayID: String, in database: isolated BudgetDatabase) throws {
        try patchScheduleAdvancementMetadata({ $0[Self.dayMarkerKey] = dayID }, in: database)
    }

    /// Clears the day marker so the next sync runs automatic posting again today,
    /// as Actual's `allowAutoPostingToRunAgainToday` does after a schedule that
    /// posts transactions is created or edited. Best effort and after the
    /// schedule commit: a marker that cannot be cleared only defers posting to
    /// tomorrow, which is the behavior before this change.
    static func allowScheduleAutoPostingAgainToday(in database: isolated BudgetDatabase) {
        guard scheduleAdvancementDayMarker(in: database) != nil else { return }
        try? patchScheduleAdvancementMetadata({ $0[Self.dayMarkerKey] = nil }, in: database)
    }

    /// Rewrites `metadata.json` with `change` applied, keeping unknown keys.
    private static func patchScheduleAdvancementMetadata(_ change: (inout [String: Any]) -> Void, in database: isolated BudgetDatabase) throws {
        let url = scheduleAdvancementMetadataURL(in: database)
        var object: [String: Any]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LocalFirstError.invalidLocalWrite("schedule advancement cannot patch metadata.json")
            }
            object = existing
        } else {
            object = [:]
        }
        change(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        var protected = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protected.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
