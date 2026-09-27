import Foundation
import GRDB

struct AccountLifecycleScheduleFacts: Sendable {
    let references: [AccountScheduleReference]
    let digest: String
    let inspectionAvailable: Bool
}

enum AccountLifecycleDigest {
    static func make(_ components: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for component in components {
            for byte in component.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

extension BudgetDatabase {
    func accountLifecycleScheduleFacts(
        accountID: String,
        db: Database
    ) throws -> AccountLifecycleScheduleFacts {
        let schedulesExist = try tableExists("schedules", db: db)
        let rulesExist = try tableExists("rules", db: db)
        guard schedulesExist || rulesExist else {
            return scheduleFacts(components: [], inspectionAvailable: true)
        }
        guard schedulesExist, rulesExist else {
            return scheduleFacts(components: ["unavailable", schedulesExist ? "schedules" : "rules"])
        }

        let scheduleColumns = try columnSet(for: "schedules", db: db)
        let ruleColumns = try columnSet(for: "rules", db: db)
        guard scheduleColumns.isSuperset(of: ["id", "rule"]),
              ruleColumns.isSuperset(of: ["id", "conditions", "actions"]) else {
            return scheduleFacts(components: [
                "unavailable",
                scheduleColumns.sorted().joined(separator: ","),
                ruleColumns.sorted().joined(separator: ","),
            ])
        }

        let rows = try accountLifecycleScheduleRows(
            scheduleColumns: scheduleColumns,
            ruleColumns: ruleColumns,
            db: db
        )
        let decoder = JSONDecoder()
        var references: [AccountScheduleReference] = []
        var components: [String] = []
        var inspectionAvailable = true
        for row in rows {
            let fact = AccountLifecycleScheduleRow(row: row)
            components.append(contentsOf: fact.canonicalComponents)
            guard let conditionsData = fact.conditions.data(using: .utf8),
                  let actionsData = fact.actions.data(using: .utf8) else {
                inspectionAvailable = false
                continue
            }
            let conditions: [RuleCondition]
            let actions: [RuleAction]
            do {
                conditions = try decoder.decode([RuleCondition].self, from: conditionsData)
                actions = try decoder.decode([RuleAction].self, from: actionsData)
            } catch {
                inspectionAvailable = false
                continue
            }
            guard !fact.ruleID.isEmpty,
                  fact.linkedRuleID == fact.ruleID,
                  actions.contains(where: { action in
                      action.operation == "link-schedule"
                          && action.value == .string(fact.scheduleID)
                  }) else {
                inspectionAvailable = false
                continue
            }
            guard fact.isLive else { continue }
            if conditions.contains(where: { accountLifecycleCondition($0, references: accountID) }) {
                references.append(AccountScheduleReference(
                    id: fact.scheduleID,
                    name: fact.name.isEmpty ? fact.scheduleID : fact.name
                ))
            }
        }
        return AccountLifecycleScheduleFacts(
            references: references,
            digest: AccountLifecycleDigest.make(components),
            inspectionAvailable: inspectionAvailable
        )
    }

    private func accountLifecycleScheduleRows(
        scheduleColumns: Set<String>,
        ruleColumns: Set<String>,
        db: Database
    ) throws -> [Row] {
        func schedule(_ name: String, fallback: String) -> String {
            scheduleColumns.contains(name) ? "s.\(quotedIdentifier(name))" : fallback
        }
        func rule(_ name: String, fallback: String) -> String {
            ruleColumns.contains(name) ? "r.\(quotedIdentifier(name))" : fallback
        }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT s.id AS schedule_id,
                       \(schedule("name", fallback: "s.id")) AS schedule_name,
                       s.rule AS schedule_rule,
                       \(schedule("active", fallback: "0")) AS schedule_active,
                       \(schedule("completed", fallback: "0")) AS schedule_completed,
                       \(schedule("posts_transaction", fallback: "0")) AS posts_transaction,
                       \(schedule("tombstone", fallback: "0")) AS schedule_tombstone,
                       r.id AS rule_id,
                       \(rule("stage", fallback: "NULL")) AS rule_stage,
                       r.conditions AS rule_conditions,
                       \(rule("conditions_op", fallback: "NULL")) AS conditions_op,
                       r.actions AS rule_actions,
                       \(rule("tombstone", fallback: "0")) AS rule_tombstone
                FROM schedules s
                LEFT JOIN rules r ON r.id = s.rule
                ORDER BY s.id
                """
        )
    }

    private func accountLifecycleCondition(
        _ condition: RuleCondition,
        references accountID: String
    ) -> Bool {
        guard condition.field == "acct" || condition.field == "account" else { return false }
        return accountLifecycleJSONValue(condition.value, contains: accountID)
    }

    private func accountLifecycleJSONValue(
        _ value: RuleJSONValue,
        contains accountID: String
    ) -> Bool {
        switch value {
        case .string(let value): value == accountID
        case .array(let values): values.contains { accountLifecycleJSONValue($0, contains: accountID) }
        case .object(let values): values.values.contains { accountLifecycleJSONValue($0, contains: accountID) }
        case .null, .bool, .number: false
        }
    }

    private func scheduleFacts(
        components: [String],
        inspectionAvailable: Bool = false
    ) -> AccountLifecycleScheduleFacts {
        AccountLifecycleScheduleFacts(
            references: [],
            digest: AccountLifecycleDigest.make(components),
            inspectionAvailable: inspectionAvailable
        )
    }
}

private struct AccountLifecycleScheduleRow {
    let scheduleID: String
    let name: String
    let ruleID: String
    let isActive: Bool
    let isCompleted: Bool
    let postsTransaction: Bool
    let isTombstoned: Bool
    let linkedRuleID: String
    let stage: String
    let conditions: String
    let conditionsJoin: String
    let actions: String
    let ruleIsTombstoned: Bool

    init(row: Row) {
        scheduleID = row["schedule_id"] ?? ""
        name = row["schedule_name"] ?? ""
        ruleID = row["schedule_rule"] ?? ""
        isActive = BudgetDatabase.flexibleLifecycleBool(row["schedule_active"])
        isCompleted = BudgetDatabase.flexibleLifecycleBool(row["schedule_completed"])
        postsTransaction = BudgetDatabase.flexibleLifecycleBool(row["posts_transaction"])
        isTombstoned = BudgetDatabase.flexibleLifecycleBool(row["schedule_tombstone"])
        linkedRuleID = row["rule_id"] ?? ""
        stage = row["rule_stage"] ?? ""
        conditions = row["rule_conditions"] ?? ""
        conditionsJoin = row["conditions_op"] ?? ""
        actions = row["rule_actions"] ?? ""
        ruleIsTombstoned = BudgetDatabase.flexibleLifecycleBool(row["rule_tombstone"])
    }

    var isLive: Bool {
        !isCompleted && !isTombstoned && !ruleIsTombstoned
    }

    var canonicalComponents: [String] {
        [
            scheduleID, name, ruleID, isActive ? "1" : "0", isCompleted ? "1" : "0",
            postsTransaction ? "1" : "0", isTombstoned ? "1" : "0", linkedRuleID,
            stage, conditions, conditionsJoin, actions, ruleIsTombstoned ? "1" : "0",
        ]
    }
}

private extension BudgetDatabase {
    nonisolated static func flexibleLifecycleBool(_ value: DatabaseValueConvertible?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? Int64 { return value != 0 }
        if let value = value as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }
}
