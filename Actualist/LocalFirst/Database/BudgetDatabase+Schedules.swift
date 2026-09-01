import Foundation
import GRDB

extension BudgetDatabase {
    func fetchRuleScheduleIndex() throws -> RuleScheduleIndex {
        try queue.read { db in
            try fetchRuleScheduleIndex(db: db)
        }
    }

    func fetchRuleScheduleIndex(db: Database) throws -> RuleScheduleIndex {
        guard try tableExists("schedules", db: db) else { return .empty }
        let columns = try columnSet(for: "schedules", db: db)
        guard columns.contains("rule") else { return .empty }

        let idSelection = columns.contains("id") ? "id" : "NULL"
        let completedSelection = columns.contains("completed") ? "completed" : "0"
        let tombstoneSelection = columns.contains("tombstone") ? "tombstone" : "0"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(idSelection) AS id, rule,
                       \(completedSelection) AS completed,
                       \(tombstoneSelection) AS tombstone
                FROM schedules
                WHERE rule IS NOT NULL
                """
        )

        var ruleIDByScheduleID: [String: String] = [:]
        var inactiveRuleIDs = Set<String>()
        for row in rows {
            guard let ruleID = row["rule"] as String?, !ruleID.isEmpty else { continue }
            if flexibleBool(row["tombstone"]) || flexibleBool(row["completed"]) {
                inactiveRuleIDs.insert(ruleID)
                continue
            }
            if let scheduleID = row["id"] as String?, !scheduleID.isEmpty {
                ruleIDByScheduleID[scheduleID] = ruleID
            }
        }
        inactiveRuleIDs.subtract(Set(ruleIDByScheduleID.values))
        return RuleScheduleIndex(
            ruleIDByScheduleID: ruleIDByScheduleID,
            completedRuleIDs: inactiveRuleIDs
        )
    }

    func draftByResolvingSchedule(
        _ draft: TransactionDraft,
        existingTransactionID: String? = nil
    ) throws -> TransactionDraft {
        var resolved = draft
        if resolved.scheduleID == nil, let existingTransactionID {
            resolved.scheduleID = try fetchTransaction(id: existingTransactionID)?.schedule
        }
        let preview = try previewRules(for: resolved)
        if preview.deletesTransaction {
            throw LocalFirstError.invalidLocalWrite("a matching rule would delete this transaction")
        }
        if let scheduleID = preview.scheduleID {
            resolved.scheduleID = scheduleID
        }
        if !preview.splits.isEmpty {
            resolved.splits = preview.splits
            resolved.isParent = true
        }
        return resolved
    }
}
