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

extension BudgetDatabase {
    func postScheduleOccurrence(
        review: ScheduleMutationReview,
        draft: TransactionDraft,
        transactionID: String,
        postedDayID: String,
        asOf today: String,
        now: Date = Date()
    ) throws -> SchedulePostingWriteReceipt {
        guard !transactionID.isEmpty,
              draft.scheduleID == review.scheduleID,
              ActualScheduleRecurrence.date(from: postedDayID) != nil,
              ActualScheduleRecurrence.date(from: today) != nil else {
            throw SchedulePostingRefusal.invalidCommand
        }
        return try sessionWritesAllowed.withLock { allowed in
            guard allowed else { throw LocalFirstError.budgetNotOpened }
            try Task.checkCancellation()
            let committed = try commitLocalPlan(now: now) { db in
                let current = try validateScheduleMutationReview(review, db: db)
                guard let accountID = current.projection.accountID,
                      let accountColumns = try? columnSet(for: "accounts", db: db),
                      accountColumns.contains("id") else {
                    throw SchedulePostingRefusal.accountUnavailable
                }
                let closed = column("closed", fallback: "0", columns: accountColumns)
                let tombstone = column("tombstone", fallback: "0", columns: accountColumns)
                guard let accountRow = try Row.fetchOne(
                    db,
                    sql: "SELECT \(closed) AS closed, \(tombstone) AS tombstone FROM accounts WHERE id = ? LIMIT 1",
                    arguments: [accountID]
                ), !flexibleBool(accountRow["closed"]), !flexibleBool(accountRow["tombstone"]) else {
                    throw SchedulePostingRefusal.accountUnavailable
                }

                guard let schedule = try fetchScheduleDetail(
                    budgetID: review.budgetID,
                    scheduleID: review.scheduleID,
                    today: today,
                    db: db
                ),
                      schedule.capabilities.canPost,
                      [.due, .upcoming, .missed].contains(schedule.status),
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
                guard try Self.actualDateValue(draft.date) == Int(expectedDay.replacingOccurrences(of: "-", with: "")),
                      draft.scheduleID == review.scheduleID else {
                    throw SchedulePostingRefusal.draftMismatch
                }
                let initialTransfer = try draft.payeeID.map {
                    try transferAccountID(ifPayee: $0, db: db) != nil
                } ?? false
                let ruleInputDraft = schedulePostingDraft(draft, isTransfer: initialTransfer)
                let evaluated = try previewRules(for: ruleInputDraft, db: db)
                guard !evaluated.deletesTransaction else {
                    throw SchedulePostingRefusal.ruleDeletesTransaction
                }
                let projected = TransactionRulePreviewProjection.applying(evaluated, to: ruleInputDraft)
                let finalTransfer = try projected.payeeID.map {
                    try transferAccountID(ifPayee: $0, db: db) != nil
                } ?? false
                let finalPayeeName = try rulePayeeName(for: projected.payeeID, db: db) ?? projected.payeeName
                let finalDraft = schedulePostingDraft(
                    projected,
                    isTransfer: finalTransfer,
                    payeeName: finalPayeeName
                )
                let trimmedName = finalDraft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
                var builderForPlan = LocalFirstSyncMessageBuilder()
                let graph = try schedulePostingTransactionGraph(
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
                let matchStartDate = scheduleTransactionLowerBound(
                    occurrenceDate: occurrenceDate,
                    matchingMode: current.projection.occurrenceMatchingMode,
                    postsTransaction: schedule.postsTransaction
                )
                let transactionDay = schedulePostingDayID(graph.primaryDate)
                guard transactionDay >= matchStartDate else {
                    throw SchedulePostingRefusal.beforeMatchWindow(earliestDayID: matchStartDate)
                }
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
                    postedDayID: schedulePostingDayID(finalDraft.date),
                    appliedMessageCount: 0,
                    affectedAccountIDs: graph.write.affectedAccountIDs,
                    affectedTransactionIDs: graph.write.affectedTransactionIDs,
                    affectedMonthIDs: [YearMonth(date: finalDraft.date).rawValue]
                )
                return LocalCommitPlan(
                    drafts: graph.write.messages,
                    action: ActionLogCommit(
                        descriptor: .createTransaction(descriptor),
                        source: .ui,
                        actionID: transactionID,
                        learningTransactionIDs: !finalDraft.isTransfer && !finalDraft.isSplit && finalDraft.categoryID != nil
                            ? [transactionID]
                            : []
                    ),
                    outcome: receipt
                )
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
    }

    private func schedulePostingDraft(
        _ draft: TransactionDraft,
        isTransfer: Bool,
        payeeName: String? = nil
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
            sortOrder: draft.sortOrder,
            reconciled: draft.reconciled,
            isParent: draft.isParent,
            splits: draft.splits,
            scheduleID: draft.scheduleID
        )
    }

    private func schedulePostingDayID(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return ActualScheduleRecurrence.dayID(from: date, calendar: calendar)
    }

}
