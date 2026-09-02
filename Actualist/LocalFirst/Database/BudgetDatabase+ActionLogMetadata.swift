import Foundation
import GRDB

extension BudgetDatabase {
    func captureMetadataActionLogFacts(
        descriptor: BudgetActionDescriptor,
        db: Database
    ) throws -> ActionLogFacts {
        switch descriptor {
        case .payee(let payee):
            let payload = PayeeBudgetAction(operation: payee.operation, names: payee.names)
            return ActionLogFacts(
                kind: .payee,
                month: "",
                summary: .payee(payload),
                inverse: .payee(payload),
                affectedCategoryIDs: []
            )
        case .rule(let rule):
            let payload = RuleBudgetAction(operation: rule.operation)
            return ActionLogFacts(
                kind: .rule,
                month: "",
                summary: .rule(payload),
                inverse: .rule(payload),
                affectedCategoryIDs: []
            )
        case .account(let account):
            let payload = AccountBudgetAction(name: account.name, offbudget: account.offbudget)
            return ActionLogFacts(
                kind: .account,
                month: "",
                summary: .account(payload),
                inverse: .account(payload),
                affectedCategoryIDs: []
            )
        case .carryover(let carryover):
            let payload = CarryoverBudgetAction(
                startMonth: carryover.startMonth,
                after: carryover.after,
                categoryCount: carryover.categoryCount
            )
            return ActionLogFacts(
                kind: .carryover,
                month: carryover.startMonth,
                summary: .carryover(payload),
                inverse: .carryover(payload),
                affectedCategoryIDs: []
            )
        case .learningPref(let learning):
            let payload = LearningPrefBudgetAction(after: learning.after)
            return ActionLogFacts(
                kind: .learningPref,
                month: "",
                summary: .learningPref(payload),
                inverse: .learningPref(payload),
                affectedCategoryIDs: []
            )
        case .transactionMetadata(let metadata):
            let payload = TransactionMetadataBudgetAction(
                month: metadata.month,
                payeeName: metadata.payeeName,
                notesChanged: metadata.notesChanged,
                clearedChanged: metadata.clearedChanged
            )
            return ActionLogFacts(
                kind: .transactionMetadata,
                month: metadata.month,
                summary: .transactionMetadata(payload),
                inverse: .transactionMetadata(payload),
                affectedCategoryIDs: []
            )
        case .assign, .move, .template, .createTransaction, .editTransaction, .deleteTransaction, .categorize:
            throw LocalFirstError.invalidLocalWrite("unexpected money-flow action in metadata capture")
        }
    }

    /// Keep the newest 25 money-flow rows. Metadata in that time window stays
    /// and does not consume a slot. If the log is metadata-only, keep 25 rows.
    /// Count and newest timestamp only. Never reads summary or inverse JSON.
    func actionLogDiagnosticSnapshot() throws -> ActionLogDiagnosticSnapshot {
        try queue.read { db in
            guard try tableExists("actualist_action_log", db: db) else {
                return .empty
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_action_log") ?? 0
            guard count > 0,
                  let newest = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(created_at) FROM actualist_action_log"
                  ),
                  let date = Self.outboxDate(newest) else {
                return ActionLogDiagnosticSnapshot(count: count, newestCreatedAt: nil)
            }
            return ActionLogDiagnosticSnapshot(count: count, newestCreatedAt: date)
        }
    }

    func pruneActionLogKeepingMoneyFlowWindow(limit: Int, db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, kind, created_at FROM actualist_action_log
                ORDER BY created_at DESC, id DESC
                """
        )
        guard !rows.isEmpty else { return }
        var moneyFlowIDs: [String] = []
        var metadata: [(id: String, createdAt: String, idTie: String)] = []
        for row in rows {
            guard let id = row["id"] as String?,
                  let kindValue = row["kind"] as String?,
                  let createdAt = row["created_at"] as String?,
                  let kind = BudgetActionKind(rawValue: kindValue) else {
                continue
            }
            if kind.isMoneyFlow {
                if moneyFlowIDs.count < limit {
                    moneyFlowIDs.append(id)
                }
            } else {
                metadata.append((id, createdAt, id))
            }
        }
        var keep = Set(moneyFlowIDs)
        if let oldestKept = moneyFlowIDs.last {
            let oldestRow = rows.first { ($0["id"] as String?) == oldestKept }
            let oldestCreated = oldestRow?["created_at"] as String? ?? ""
            for item in metadata {
                if item.createdAt > oldestCreated
                    || (item.createdAt == oldestCreated && item.idTie >= oldestKept) {
                    keep.insert(item.id)
                }
            }
        } else {
            keep.formUnion(metadata.prefix(limit).map(\.id))
        }
        let allIDs = rows.compactMap { $0["id"] as String? }
        let stale = allIDs.filter { !keep.contains($0) }
        guard !stale.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: stale.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM actualist_action_log WHERE id IN (\(placeholders))",
            arguments: StatementArguments(stale)
        )
    }
}
