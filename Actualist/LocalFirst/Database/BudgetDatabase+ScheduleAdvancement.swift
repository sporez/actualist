import Foundation

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
    /// The day marker already matched, so nothing ran and refusals are unknown.
    var skippedForToday = false
}

extension BudgetDatabase {
    /// Posts due or missed automatic schedules and advances paid occurrences.
    /// `metadata.json` `lastScheduleRun` is local, like Actual's metadata marker,
    /// and is patched with JSONSerialization so unknown keys survive. It is
    /// written when the run finishes. A typed `SchedulePostingRefusal` skips only
    /// that schedule and the day is still marked done (Actual sets
    /// `lastScheduleRun` after any successful sync and never retries a refusal
    /// the same day). Cancellation and any other error stop the run with the
    /// marker unset, so the next sync retries.
    func advanceSchedules(
        budgetID: String,
        today: String,
        now: Date = Date()
    ) throws -> ScheduleAdvancementResult {
        if scheduleAdvancementDayMarker() == today {
            return ScheduleAdvancementResult(receipts: [], scheduleMutated: false, skippedForToday: true)
        }

        var receipts: [SchedulePostingWriteReceipt] = []
        var refusals: [ScheduleAutoPostRefusal] = []
        var scheduleMutated = false
        let ordered = schedulesInAdvancementOrder(
            Array(try fetchSchedules(budgetID: budgetID, today: today).detailsByID.values)
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
                    receipts: &receipts,
                    refusals: &refusals,
                    scheduleMutated: &scheduleMutated
                )
            } catch is CancellationError {
                return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
            }
            if step == .stopRun {
                return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
            }
        }

        if Task.isCancelled {
            return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
        }
        // A marker write failure must not hide committed posts. Leaving the
        // marker unset makes the next successful sync retry.
        do {
            try writeScheduleAdvancementDayMarker(today)
        } catch {
            return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
        }
        return ScheduleAdvancementResult(receipts: receipts, scheduleMutated: scheduleMutated, refusals: refusals)
    }

    private enum ScheduleAdvancementStep {
        case nextSchedule
        case stopRun
    }

    private static let maximumOccurrencesPerSchedule = 366
    private static let dayMarkerKey = "lastScheduleRun"

    private func advanceSchedule(
        _ scheduleID: String,
        budgetID: String,
        today: String,
        now: Date,
        receipts: inout [SchedulePostingWriteReceipt],
        refusals: inout [ScheduleAutoPostRefusal],
        scheduleMutated: inout Bool
    ) throws -> ScheduleAdvancementStep {
        for _ in 0..<Self.maximumOccurrencesPerSchedule {
            try Task.checkCancellation()
            guard let detail = try fetchScheduleDetail(budgetID: budgetID, scheduleID: scheduleID, today: today) else {
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
                let statusBefore = detail.status
                let isRecurring = detail.dateRule.recurrence != nil
                do {
                    receipts.append(try postScheduledOccurrence(
                        detail,
                        budgetID: budgetID,
                        today: today,
                        now: now
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
                    scheduleMutated: &scheduleMutated
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
                    scheduleMutated: &scheduleMutated
                )
                if moved != .dateChanged {
                    return moved == .stopRun ? .stopRun : .nextSchedule
                }
            case .completeOneTime:
                do {
                    let result = try completeSchedule(
                        review: scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID),
                        now: now
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

    private func postScheduledOccurrence(
        _ detail: ScheduleDetail,
        budgetID: String,
        today: String,
        now: Date
    ) throws -> SchedulePostingWriteReceipt {
        guard let accountID = detail.account.id,
              let amount = detail.amount.postingAmount,
              let postedDayID = detail.effectiveNextDate,
              let transactionDate = Self.postingDate(postedDayID) else {
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
            review: scheduleMutationReview(budgetID: budgetID, scheduleID: detail.id),
            draft: draft,
            transactionID: UUID().uuidString,
            postedDayID: postedDayID,
            asOf: today,
            source: .automatic,
            now: now
        )
    }

    /// Moves a recurring next date from the day after the current occurrence.
    /// This is not user skip: `nextDateAfterSkip` is not used.
    private func advanceRecurringOccurrence(
        _ scheduleID: String,
        budgetID: String,
        today: String,
        now: Date,
        scheduleMutated: inout Bool
    ) throws -> RecurringAdvanceStep {
        try Task.checkCancellation()
        guard let detail = try fetchScheduleDetail(budgetID: budgetID, scheduleID: scheduleID, today: today),
              let currentDayID = detail.effectiveNextDate,
              detail.dateRule.recurrence != nil else {
            return .dateUnchanged
        }
        let review: ScheduleMutationReview
        do {
            review = try scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID)
        } catch is CancellationError {
            return .stopRun
        } catch {
            return .dateUnchanged
        }
        let committed: (outcome: Bool, appliedCount: Int)
        do {
            committed = try commitLocalPlan(now: now) { db in
                let current = try validateScheduleMutationReview(review, db: db)
                guard let recurrence = current.projection.dateRule.recurrence,
                      let effective = current.effectiveNextDate,
                      let next = current.review.uniqueNextDate,
                      let advanced = try advancedRecurringDayID(recurrence: recurrence, currentDayID: effective),
                      advanced != effective else {
                    return LocalCommitPlan(drafts: [], action: nil, outcome: false)
                }
                var builder = LocalFirstSyncMessageBuilder()
                let messages = try localNextDateMessages(
                    rowID: next.id,
                    date: advanced,
                    baseTimestamp: next.baseTimestamp,
                    builder: &builder
                )
                return LocalCommitPlan(drafts: messages, action: nil, outcome: true)
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
              let updated = try fetchScheduleDetail(budgetID: budgetID, scheduleID: scheduleID, today: today)?.effectiveNextDate,
              updated != currentDayID else {
            return .dateUnchanged
        }
        return .dateChanged
    }

    private func advancedRecurringDayID(
        recurrence: ActualScheduleRecurrence,
        currentDayID: String
    ) throws -> String? {
        guard let currentDate = ActualScheduleRecurrence.date(from: currentDayID),
              let dayAfter = Calendar.actualScheduleGregorian.date(byAdding: .day, value: 1, to: currentDate) else {
            return nil
        }
        return try recurrence.nextOccurrence(
            onOrAfter: ActualScheduleRecurrence.dayID(from: dayAfter)
        )
    }

    /// Same local next-date messages the skip writer enqueues (`base: false`).
    private func localNextDateMessages(
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
                value: scheduleDateValue(date)
            ),
            try builder.makeMessage(
                dataset: "schedules_next_date",
                row: rowID,
                column: "local_next_date_ts",
                value: .int(baseTimestamp)
            )
        ]
    }

    private func schedulesInAdvancementOrder(_ details: [ScheduleDetail]) -> [ScheduleDetail] {
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

    /// Hour-12 local date, matching manual schedule posting. Not UTC midnight.
    private static func postingDate(_ dayID: String) -> Date? {
        guard ActualScheduleRecurrence.date(from: dayID) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let parts = dayID.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12
        ))
    }

    private var scheduleAdvancementMetadataURL: URL {
        databaseURL.deletingLastPathComponent().appending(path: "metadata.json")
    }

    private func scheduleAdvancementDayMarker() -> String? {
        let url = scheduleAdvancementMetadataURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marker = object[Self.dayMarkerKey] as? String,
              !marker.isEmpty else {
            return nil
        }
        return marker
    }

    private func writeScheduleAdvancementDayMarker(_ dayID: String) throws {
        let url = scheduleAdvancementMetadataURL
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
        object[Self.dayMarkerKey] = dayID
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
