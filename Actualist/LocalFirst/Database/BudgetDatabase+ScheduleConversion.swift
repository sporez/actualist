import Foundation
import GRDB

struct ScheduleConversionWriteReceipt: Hashable, Sendable {
    let scheduleID: String
    let sourceTransactionIDs: [String]
    let sourceAccountID: String
    let sourceMonthID: String
    let appliedMessageCount: Int
}

private struct ScheduleConversionRow {
    let transaction: ActualTransaction
    let rawPayeeID: String?
    let transferID: String?
    let isTransferPayee: Bool
}

extension BudgetDatabase {
    func scheduleConversionReview(
        context: ScheduleConversionSessionContext,
        transactionID: String,
        asOfDayID: String,
        identity: ScheduleConversionIdentity
    ) throws -> ScheduleConversionReview {
        guard !transactionID.isEmpty,
              ActualScheduleRecurrence.date(from: asOfDayID) != nil else {
            throw ScheduleConversionError.unsupportedSource("The selected transaction or review date is invalid.")
        }
        return try queue.read { db in
            let facts = try scheduleConversionFacts(transactionID: transactionID, db: db)
            try validateScheduleConversionSource(facts, asOfDayID: asOfDayID, db: db)
            return ScheduleConversionReview(
                context: context,
                sourceTransactionID: transactionID,
                asOfDayID: asOfDayID,
                identity: identity,
                family: facts.map {
                    ScheduleConversionTransactionFact(
                        transaction: $0.transaction,
                        rawPayeeID: $0.rawPayeeID,
                        transferID: $0.transferID,
                        isTransferPayee: $0.isTransferPayee
                    )
                }
            )
        }
    }

    func convertFutureTransaction(
        review: ScheduleConversionReview,
        now: Date = Date()
    ) throws -> ScheduleConversionWriteReceipt {
        guard !review.sourceTransactionID.isEmpty,
              !review.family.isEmpty,
              review.family.first?.transaction.id == review.sourceTransactionID else {
            throw ScheduleConversionError.reviewChanged
        }
        return try sessionWritesAllowed.withLock { allowed in
            guard allowed else { throw LocalFirstError.budgetNotOpened }
            try Task.checkCancellation()
            let committed: (outcome: ScheduleConversionWriteReceipt, appliedCount: Int)
            do {
                committed = try commitLocalPlan(now: now) { db in
                    let currentDay = Self.scheduleConversionToday()
                    guard review.asOfDayID == currentDay else {
                        throw ScheduleConversionError.reviewChanged
                    }
                    let currentFacts: [ScheduleConversionRow]
                    do {
                        currentFacts = try scheduleConversionFacts(
                            transactionID: review.sourceTransactionID,
                            db: db
                        )
                    } catch ScheduleConversionError.unsupportedSource(_) {
                        throw ScheduleConversionError.reviewChanged
                    }
                    try validateScheduleConversionSource(currentFacts, asOfDayID: currentDay, db: db)
                    let currentReviewFacts = currentFacts.map {
                        ScheduleConversionTransactionFact(
                            transaction: $0.transaction,
                            rawPayeeID: $0.rawPayeeID,
                            transferID: $0.transferID,
                            isTransferPayee: $0.isTransferPayee
                        )
                    }
                    guard currentReviewFacts == review.family else {
                        throw ScheduleConversionError.reviewChanged
                    }
                    guard let source = currentFacts.first?.transaction,
                          !source.account.isEmpty,
                          let monthID = source.date.actualYearMonth,
                          !monthID.isEmpty else {
                        throw ScheduleConversionError.unsupportedSource("The transaction account or date is unavailable.")
                    }
                    let accountID = source.account

                    var builder = LocalFirstSyncMessageBuilder()
                    let plan = ScheduleTransactionConversionPlanner.plan(from: source)
                    let link = RuleJSONValue.object([
                        "op": .string("link-schedule"),
                        "value": .string(review.identity.scheduleID)
                    ])
                    let conditionsJSON = try scheduleConversionJSON(plan.conditions)
                    let actionsJSON = try scheduleConversionJSON([link] + plan.actions)
                    let scheduleName = "Auto-created future transaction (\(source.date)) · \(review.identity.scheduleID.prefix(8))"
                    var messages = try scheduleCreationMessages(
                        ScheduleCreationMessagePlanRequest(
                            identity: ScheduleCreateIdentity(
                                scheduleID: review.identity.scheduleID,
                                ruleID: review.identity.ruleID,
                                nextDateID: review.identity.nextDateID
                            ),
                            name: scheduleName,
                            postsTransaction: plan.postsTransaction,
                            customUpcomingLength: nil,
                            conditionsJSON: conditionsJSON,
                            actionsJSON: actionsJSON,
                            nextDate: source.date,
                            now: now
                        ),
                        db: db,
                        builder: &builder
                    )
                    let transactionColumns = try resolveTransactionRowColumns(db: db)
                    guard transactionColumns.hasTombstone else {
                        throw ScheduleConversionError.unsupportedSource("This budget cannot safely remove the original transaction.")
                    }
                    for fact in currentFacts {
                        guard let transactionID = fact.transaction.id else {
                            throw ScheduleConversionError.reviewChanged
                        }
                        messages.append(try tombstoneMessage(rowID: transactionID, builder: &builder))
                    }
                    return LocalCommitPlan(
                        drafts: messages,
                        action: nil,
                        outcome: ScheduleConversionWriteReceipt(
                            scheduleID: review.identity.scheduleID,
                            sourceTransactionIDs: currentFacts.compactMap { $0.transaction.id },
                            sourceAccountID: accountID,
                            sourceMonthID: monthID,
                            appliedMessageCount: 0
                        )
                    )
                }
            } catch ScheduleMutationCommandError.identityConflict {
                throw ScheduleConversionError.identityConflict
            } catch ScheduleMutationCommandError.unsupportedCapability(let reason) {
                throw ScheduleConversionError.unsupportedSource(reason)
            }
            let receipt = committed.outcome
            return ScheduleConversionWriteReceipt(
                scheduleID: receipt.scheduleID,
                sourceTransactionIDs: receipt.sourceTransactionIDs,
                sourceAccountID: receipt.sourceAccountID,
                sourceMonthID: receipt.sourceMonthID,
                appliedMessageCount: committed.appliedCount
            )
        }
    }

    private func scheduleConversionFacts(
        transactionID: String,
        db: Database
    ) throws -> [ScheduleConversionRow] {
        let columns = try requiredColumns(table: "transactions", required: ["id", "date", "amount"], db: db)
        let split = transactionSplitQueryExpressions(columns: columns)
        let normalizedDate = normalizedDateExpression(split.qualifiedDate)
        let joins = try transactionReadJoins(
            db: db,
            split: split,
            transactionColumns: columns,
            includeNames: true
        )
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(transactionReadSelectList(split: split, joins: joins, normalizedDate: normalizedDate)),
                       \(split.qualifiedPayee) AS conversion_raw_payee_id,
                       \(joins.transferIDExpression) AS conversion_transfer_id,
                       (\(joins.isTransferExpression)) AS conversion_is_transfer_payee
                FROM transactions t
                \(joins.sql)
                \(split.parentJoin())
                WHERE (t.id = ? OR \(split.effectiveParentID) = ?)
                  AND \(split.liveEffectivePredicate())
                ORDER BY \(split.defaultOrder(normalizedDate: normalizedDate))
                """,
            arguments: [transactionID, transactionID]
        )
        let converted = rows.map { row in
            ScheduleConversionRow(
                transaction: mapTransactionRow(row),
                rawPayeeID: (row["conversion_raw_payee_id"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                transferID: (row["conversion_transfer_id"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                isTransferPayee: flexibleBool(row["conversion_is_transfer_payee"])
            )
        }
        guard let root = converted.first(where: { $0.transaction.id == transactionID }),
              !root.transaction.isChild else {
            throw ScheduleConversionError.unsupportedSource("Select the original transaction, not a split child.")
        }
        let rootID = root.transaction.id
        let children = converted.filter { $0.transaction.isChild && $0.transaction.parentID == rootID }
        guard converted.count == 1 + children.count else {
            throw ScheduleConversionError.unsupportedSource("The transaction family is not a supported split.")
        }
        let ordered = [root] + children
        guard root.transaction.isParent else { return ordered }
        let parent = ScheduleConversionRow(
            transaction: root.transaction.replacingSubtransactions(children.map(\.transaction)),
            rawPayeeID: root.rawPayeeID,
            transferID: root.transferID,
            isTransferPayee: root.isTransferPayee
        )
        return [parent] + children
    }

    private func validateScheduleConversionSource(
        _ facts: [ScheduleConversionRow],
        asOfDayID: String,
        db: Database
    ) throws {
        guard let root = facts.first?.transaction,
              root.id != nil,
              ActualScheduleRecurrence.date(from: root.date) != nil else {
            throw ScheduleConversionError.unsupportedSource("The transaction date is unavailable.")
        }
        guard root.date > asOfDayID else { throw ScheduleConversionError.transactionNotFuture }
        if root.isParent {
            guard !root.subtransactions.isEmpty,
                  facts.count == root.subtransactions.count + 1 else {
                throw ScheduleConversionError.unsupportedSource("The split transaction family is incomplete.")
            }
        } else if facts.count != 1 || root.isChild {
            throw ScheduleConversionError.unsupportedSource("The transaction family is not a supported split.")
        }
        let ids = facts.compactMap { $0.transaction.id }
        guard ids.count == facts.count, Set(ids).count == ids.count else {
            throw ScheduleConversionError.unsupportedSource("The transaction family contains duplicate identities.")
        }
        guard facts.allSatisfy({ fact in
            fact.transaction.account == root.account
                && fact.transaction.date == root.date
                && !fact.transaction.reconciled
                && fact.transferID == nil
                && !fact.isTransferPayee
        }) else {
            if facts.contains(where: { $0.transaction.reconciled }) {
                throw ScheduleConversionError.unsupportedSource("Reconciled transaction families cannot be converted.")
            }
            if facts.contains(where: { $0.transferID != nil || $0.isTransferPayee }) {
                throw ScheduleConversionError.unsupportedSource("Transfer transactions cannot be converted to schedules.")
            }
            throw ScheduleConversionError.unsupportedSource("The split family has inconsistent account or date values.")
        }
        try validateConversionAccount(root.account, db: db)
        if let payeeID = root.payee, !payeeID.isEmpty {
            try validateCanonicalConversionPayee(payeeID, rawPayeeID: facts.first?.rawPayeeID, db: db)
        }
    }

    private func validateConversionAccount(_ accountID: String, db: Database) throws {
        _ = try requiredColumns(table: "accounts", required: ["id", "closed", "tombstone"], db: db)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT closed, tombstone FROM accounts WHERE id = ? LIMIT 1",
            arguments: [accountID]
        ), !flexibleBool(row["closed"]), !flexibleBool(row["tombstone"]) else {
            throw ScheduleConversionError.unsupportedSource("The transaction account is unavailable or closed.")
        }
    }

    private func validateCanonicalConversionPayee(
        _ payeeID: String,
        rawPayeeID: String?,
        db: Database
    ) throws {
        let mappings = try requiredColumns(table: "payee_mapping", required: ["id"], db: db)
        guard let targetColumn = ["targetId", "target_id"].first(where: mappings.contains) else {
            throw ScheduleConversionError.unsupportedSource("The transaction payee mapping is unavailable.")
        }
        let payees = try requiredColumns(table: "payees", required: ["id"], db: db)
        if let rawPayeeID, rawPayeeID != payeeID {
            guard try Row.fetchOne(
                db,
                sql: """
                    SELECT id FROM payee_mapping
                    WHERE id = ? AND \(quotedIdentifier(targetColumn)) = ?
                      AND \(predicateForLiveRows(columns: mappings))
                    LIMIT 1
                    """,
                arguments: [rawPayeeID, payeeID]
            ) != nil else {
                throw ScheduleConversionError.unsupportedSource("The transaction payee alias no longer resolves to its canonical payee.")
            }
        }
        guard try Row.fetchOne(
            db,
            sql: """
                SELECT mapping.id
                FROM payee_mapping mapping
                JOIN payees payee ON payee.id = mapping.\(quotedIdentifier(targetColumn))
                WHERE mapping.id = ? AND mapping.\(quotedIdentifier(targetColumn)) = ?
                  AND \(predicateForLiveRows(columns: mappings, tableAlias: "mapping"))
                  AND \(predicateForLiveRows(columns: payees, tableAlias: "payee"))
                LIMIT 1
                """,
            arguments: [payeeID, payeeID]
        ) != nil else {
            throw ScheduleConversionError.unsupportedSource("The transaction payee has no live canonical self-mapping.")
        }
    }

    private func scheduleConversionJSON(_ values: [RuleJSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(values), as: UTF8.self)
    }

    private static func scheduleConversionToday(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return ActualScheduleRecurrence.dayID(from: now, calendar: calendar)
    }
}
