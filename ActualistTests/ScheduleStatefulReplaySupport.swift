import Foundation
import GRDB
@testable import Actualist

/// Replays the stateful Schedules cases through the `BudgetDatabase` operations the store calls.
///
/// Steps test: before every step the fixture's snapshot of the state before it (rows written by Actual's own
/// `createSchedule` and earlier steps) is seeded into the starter database, so a divergence in one step cannot
/// carry into the next. Then the matching production operation runs (`advanceSchedules`, `skipNextDate`,
/// `updateSchedule`, `postScheduleOccurrence`) with the step's day as `today` and its local noon as `now`, and the
/// database projection is compared with the step's `after` snapshot. A `payNextDate` step is an oracle input (a
/// transaction inserted for the schedule), so only its snapshot is re-read. Creation test: `createSchedule`
/// replays each setup schedule against a fresh database and the result is compared with the `before` snapshot.
/// Compared and excluded fields are in `scripts/schedule-parity/README.md` ("Swift replay").
@MainActor
enum ScheduleStatefulReplay {
    static let budgetID = "schedule-oracle-replay"

    struct Comparison {
        let label: String
        let expected: OracleValue
        let actual: OracleValue
        var mismatches: [ReplayMismatch] {
            var comparison = OracleComparison()
            comparison.compare(expected: expected, actual: actual, path: label)
            return comparison.mismatches
        }
    }

    // MARK: Steps

    static func replaySteps(_ entry: [String: Any]) async throws -> [Comparison] {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let setup = try OracleJSON.object(entry["setup"], "setup")
        let before = try OracleJSON.object(entry["before"], "before")
        let steps = try OracleJSON.objects(entry["steps"], "steps")
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await makeDatabase(in: directory)
        try await seed(database, setup: setup, before: before)

        var comparisons: [Comparison] = []
        var previous = before
        for (index, step) in steps.enumerated() {
            let after = try OracleJSON.object(step["after"], "after of step \(index)")
            let args = try OracleJSON.object(step["args"], "args of step \(index)")
            let op = try OracleJSON.string(step, "op")
            let today = try OracleJSON.string(step, "today")
            let label = "step\(index)(\(op))"
            // Every step starts from the oracle's state before it, so one divergence cannot cascade into
            // the steps after it and each step's result is attributed to its own operation.
            try await seed(database, setup: setup, before: op == "payNextDate" ? after : previous)
            var refusals: [String] = []
            var failure: String?
            do {
                // A `payNextDate` step is an oracle input (a transaction inserted for the schedule); its rows are
                // already part of the snapshot, so there is no production operation to run.
                if op != "payNextDate" {
                    refusals = try await run(op: op, args: args, setup: setup, database: database, today: today)
                }
            } catch {
                failure = "threw \(error)"
            }
            comparisons.append(Comparison(
                label: label,
                expected: .object(["completes": .string("yes"), "refusals": .string("none")]),
                actual: .object(["completes": .string(failure ?? "yes"), "refusals": .string(refusals.isEmpty ? "none" : refusals.joined(separator: "; "))])
            ))
            var expected = try expectedProjection(after, today: today)
            expected["error"] = (step["error"] is NSNull) || step["error"] == nil ? .null : .string("error")
            var actualFields = try await projection(of: database, today: today)
            actualFields["error"] = .null
            comparisons.append(Comparison(label: label, expected: .object(expected), actual: .object(actualFields)))
            previous = after
        }
        return comparisons
    }

    private static func run(
        op: String,
        args: [String: Any],
        setup: [String: Any],
        database: BudgetDatabase,
        today: String
    ) async throws -> [String] {
        let now = try ScheduleOracleFixture.noon(today)
        var refusals: [String] = []
        let scheduleKey = args["schedule"] as? String
        let scheduleID = scheduleKey.map { "schedule-\($0)" }
        switch op {
        case "advance":
            // The day marker would make a second run on the same day skip; Actual keeps no such marker per call.
            let markerURL = await database.databaseURL.deletingLastPathComponent().appending(path: "metadata.json")
            try? FileManager.default.removeItem(at: markerURL)
            let result = try await database.advanceSchedules(budgetID: budgetID, today: today, now: now)
            refusals = result.refusals.map { "\($0.scheduleID) \($0.occurrenceDayID) \($0.refusal)" }
        case "skip":
            let review = try await database.scheduleMutationReview(budgetID: budgetID, scheduleID: required(scheduleID))
            _ = try await database.skipNextDate(review: review, now: now)
        case "setNextDate":
            // Only the two replayable combinations reach here; see `stepOracleOnlyReason` in cases.mjs.
            let review = try await database.scheduleMutationReview(budgetID: budgetID, scheduleID: required(scheduleID))
            if args["reset"] as? Bool == true {
                var fields = ScheduleEditFields()
                fields.resetNextDate = true
                _ = try await database.updateSchedule(review: review, fields: fields, asOfDayID: today, now: now)
            } else {
                _ = try await database.skipNextDate(review: review, now: now)
            }
        case "update":
            let review = try await database.scheduleMutationReview(budgetID: budgetID, scheduleID: required(scheduleID))
            let definition = try setupSchedule(setup, key: required(scheduleKey))
            var fields = ScheduleEditFields()
            if let date = args["date"] {
                let condition = try ruleCondition(field: "date", op: definition["dateOp"] as? String ?? "is", value: date)
                fields.dateRule = .set(ScheduleRuleProjection.dateRule(from: condition))
            }
            if let amount = OracleJSON.int(args["amount"]) {
                fields.amount = .set(definition["amountOp"] as? String == "isapprox" ? .approximate(amount) : .exact(amount))
            }
            fields.resetNextDate = args["resetNextDate"] as? Bool ?? false
            _ = try await database.updateSchedule(review: review, fields: fields, asOfDayID: today, now: now)
        case "post":
            try await post(database, scheduleID: required(scheduleID), today: today, postsToday: args["todayDate"] as? Bool ?? false, now: now)
        default:
            throw OracleReplayError.malformedFixture("unsupported step \(op)")
        }
        return refusals
    }

    /// Builds the draft the way `LocalFirstActualStore.postSchedule` does, then posts through the database.
    private static func post(
        _ database: BudgetDatabase,
        scheduleID: String,
        today: String,
        postsToday: Bool,
        now: Date
    ) async throws {
        let review = try await database.scheduleMutationReview(budgetID: budgetID, scheduleID: scheduleID)
        guard let detail = try await database.fetchScheduleDetail(budgetID: budgetID, scheduleID: scheduleID, today: today),
              let accountID = detail.account.id,
              let amount = detail.amount.postingAmount,
              let scheduled = detail.effectiveNextDate else {
            throw OracleReplayError.malformedFixture("schedule \(scheduleID) is not postable")
        }
        let postedDayID = postsToday ? today : scheduled
        let parts = postedDayID.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard parts.count == 3, let date = calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12
        )) else {
            throw OracleReplayError.malformedFixture("bad day \(postedDayID)")
        }
        let draft = TransactionDraft(
            accountID: accountID,
            date: date,
            amountMinorUnits: amount,
            payeeID: detail.payee.postingPayeeID,
            payeeName: detail.payee.name ?? "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            scheduleID: detail.id
        )
        _ = try await database.postScheduleOccurrence(
            review: review,
            draft: draft,
            transactionID: UUID().uuidString,
            postedDayID: postedDayID,
            asOf: today,
            now: now
        )
    }

    private static func required(_ value: String?) throws -> String {
        guard let value else { throw OracleReplayError.malformedFixture("step has no schedule") }
        return value
    }

    // MARK: Creation

    static func replayCreation(_ entry: [String: Any]) async throws -> [Comparison] {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        let setup = try OracleJSON.object(entry["setup"], "setup")
        let before = try OracleJSON.object(entry["before"], "before")
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await makeDatabase(in: directory)
        try await seed(database, setup: setup, before: before, includingSchedules: false)

        let ids = try referencedIDs(setup: setup, before: before)
        let schedules = try OracleJSON.objects(setup["schedules"], "schedules")
            .sorted { (($0["createdOn"] as? String) ?? "") < (($1["createdOn"] as? String) ?? "") }
        var failures: [String] = []
        for schedule in schedules {
            let key = try OracleJSON.string(schedule, "key")
            let createdOn = try OracleJSON.string(schedule, "createdOn")
            let condition = try ruleCondition(field: "date", op: schedule["dateOp"] as? String ?? "is", value: schedule["date"] ?? NSNull())
            let command = ScheduleCreateCommand(
                budgetID: budgetID,
                identity: ScheduleCreateIdentity(scheduleID: "schedule-\(key)", ruleID: "rule-\(key)", nextDateID: "next-\(key)"),
                name: schedule["name"] as? String,
                definition: ScheduleDefinitionDraft(
                    accountID: try required(ids.accounts[try OracleJSON.string(schedule, "accountKey")]),
                    payeeMappingID: (schedule["payeeKey"] as? String).flatMap { ids.payees[$0] },
                    amount: try amountDraft(schedule),
                    dateRule: ScheduleRuleProjection.dateRule(from: condition)
                ),
                postsTransaction: schedule["postsTransaction"] as? Bool ?? false,
                customUpcomingLength: schedule["customUpcomingLength"] as? String,
                asOfDayID: createdOn
            )
            do {
                _ = try await database.createSchedule(command, now: try ScheduleOracleFixture.noon(createdOn))
            } catch let error as ScheduleMutationCommandError {
                failures.append("\(key) threw \(error)")
            }
        }
        // A refused creation leaves nothing to project, so only the refusal is compared.
        if !failures.isEmpty {
            return [Comparison(
                label: "created",
                expected: .object(["completes": .string("yes")]),
                actual: .object(["completes": .string(failures.joined(separator: "; "))])
            )]
        }

        let actual = try await creationProjection(of: database)
        let expected = try expectedCreationProjection(before)
        return [Comparison(label: "created", expected: .object(expected), actual: .object(actual))]
    }

    private static func amountDraft(_ schedule: [String: Any]) throws -> ScheduleAmountDraft {
        switch schedule["amountOp"] as? String {
        case "isapprox":
            return .approximate(OracleJSON.int(schedule["amount"]) ?? 0)
        case "isbetween":
            let range = try OracleJSON.object(schedule["amount"], "amount")
            return .range(lower: OracleJSON.int(range["num1"]) ?? 0, upper: OracleJSON.int(range["num2"]) ?? 0)
        default:
            return .exact(OracleJSON.int(schedule["amount"]) ?? 0)
        }
    }

    private static func ruleCondition(field: String, op: String, value: Any) throws -> RuleCondition {
        let object: [String: Any] = ["field": field, "op": op, "value": value]
        return try JSONDecoder().decode(RuleCondition.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func setupSchedule(_ setup: [String: Any], key: String) throws -> [String: Any] {
        guard let schedule = try OracleJSON.objects(setup["schedules"], "schedules").first(where: { $0["key"] as? String == key }) else {
            throw OracleReplayError.malformedFixture("no setup schedule \(key)")
        }
        return schedule
    }

    // MARK: Projections

    /// Fields compared per transaction. Not compared: `id` (the replay's ids are its own) and `sort_order` and
    /// `raw_synced_data` (derived from the clock and the sync source).
    nonisolated private static let transactionColumns = [
        "acct", "amount", "date", "description", "schedule", "cleared", "category", "notes", "tombstone",
        "isParent", "isChild", "parent_id", "reconciled", "starting_balance_flag", "financial_id",
        "imported_description", "transferred_id", "error", "pending", "type", "location",
    ]
    nonisolated private static let scheduleColumns = ["completed", "posts_transaction", "name", "custom_upcoming_length", "tombstone"]

    private static func transactionOrder(_ lhs: OracleValue, _ rhs: OracleValue) -> Bool {
        func key(_ value: OracleValue) -> String {
            guard case .object(let fields) = value else { return "" }
            return ["date", "schedule", "amount", "acct", "description"]
                .map { fields[$0, default: .null].canonical }.joined(separator: "|")
        }
        return key(lhs) < key(rhs)
    }

    private static func expectedProjection(_ after: [String: Any], today: String) throws -> [String: OracleValue] {
        var fields: [String: OracleValue] = [:]
        fields["schedules"] = try keyed(after["schedules"], idKey: "id", columns: scheduleColumns)
        fields["nextDates"] = try keyed(
            after["nextDates"], idKey: "schedule_id", columns: ["local_next_date", "base_next_date", "localIsEffective"]
        )
        var effective: [String: OracleValue] = [:]
        for row in try OracleJSON.objects(after["effective"], "effective") {
            effective[try OracleJSON.string(row, "id")] = .object([
                "nextDate": try OracleValue(json: row["nextDate"] ?? NSNull()),
                "completed": try OracleValue(json: row["completed"] ?? NSNull()),
                "status": try OracleValue(json: row["status"] ?? NSNull()),
            ])
        }
        fields["effective"] = .object(effective)
        let transactions = try OracleJSON.objects(after["transactions"], "transactions").map { row -> OracleValue in
            .object(try Dictionary(uniqueKeysWithValues: transactionColumns.map { ($0, try OracleValue(json: row[$0] ?? NSNull())) }))
        }
        fields["transactions"] = .array(transactions.sorted(by: transactionOrder))
        fields["rules"] = try ruleSummaries(
            try OracleJSON.objects(after["rules"], "rules").map { ($0["conditions"] as? [[String: Any]] ?? [], $0["actions"] as? [[String: Any]] ?? []) }
        )
        return fields
    }

    private static func projection(of database: BudgetDatabase, today: String) async throws -> [String: OracleValue] {
        let queue = await database.queue
        let columns = scheduleColumns.joined(separator: ", ")
        let transactionList = transactionColumns.joined(separator: ", ")
        let raw = try await queue.read { db -> (schedules: OracleValue, nextDates: OracleValue, transactions: [OracleValue], rules: [[String?]]) in
            (
                keyed(try Row.fetchAll(db, sql: "SELECT id, \(columns) FROM schedules ORDER BY id"), idKey: "id", columns: scheduleColumns),
                keyed(try Row.fetchAll(db, sql: """
                    SELECT schedule_id, local_next_date, base_next_date,
                           (local_next_date_ts = base_next_date_ts) AS localIsEffective
                    FROM schedules_next_date ORDER BY schedule_id
                    """), idKey: "schedule_id", columns: ["local_next_date", "base_next_date", "localIsEffective"]),
                try Row.fetchAll(db, sql: "SELECT \(transactionList) FROM transactions").map { row in
                    OracleValue.object(Dictionary(uniqueKeysWithValues: transactionColumns.map { ($0, OracleValue.databaseValue(row[$0] as DatabaseValue)) }))
                },
                try Row.fetchAll(db, sql: "SELECT conditions, actions FROM rules WHERE tombstone = 0").map { row in
                    [row["conditions"] as String?, row["actions"] as String?]
                }
            )
        }
        var fields: [String: OracleValue] = [:]
        fields["schedules"] = raw.schedules
        fields["nextDates"] = raw.nextDates
        let loaded = try await database.fetchSchedules(budgetID: budgetID, today: today)
        var effective: [String: OracleValue] = [:]
        for detail in loaded.detailsByID.values {
            effective[detail.id] = .object([
                "nextDate": detail.effectiveNextDate.map { .string($0) } ?? .null,
                "completed": .number(detail.completed ? 1 : 0),
                "status": .string(detail.status.rawValue),
            ])
        }
        fields["effective"] = .object(effective)
        fields["transactions"] = .array(raw.transactions.sorted(by: transactionOrder))
        fields["rules"] = try ruleSummaries(raw.rules.map { (parseArray($0[0]), parseArray($0[1])) })
        return fields
    }

    private static func creationProjection(of database: BudgetDatabase) async throws -> [String: OracleValue] {
        let projected = try await projection(of: database, today: "2026-10-11")
        return creationFields(projected)
    }

    private static func expectedCreationProjection(_ before: [String: Any]) throws -> [String: OracleValue] {
        creationFields(try expectedProjection(before, today: "2026-10-11"))
    }

    /// Creation compares the stored schedule fields (not `completed`, which creation cannot set), the next-date
    /// rows and the rule summaries. Status and transactions depend on a later "today".
    private static func creationFields(_ projected: [String: OracleValue]) -> [String: OracleValue] {
        var schedules: [String: OracleValue] = [:]
        if case .object(let rows)? = projected["schedules"] {
            for (id, row) in rows {
                if case .object(var columns) = row {
                    columns["completed"] = nil
                    schedules[id] = .object(columns)
                }
            }
        }
        return [
            "schedules": .object(schedules),
            "nextDates": projected["nextDates", default: .null],
            "rules": projected["rules", default: .null],
        ]
    }

    private static func parseArray(_ json: String?) -> [[String: Any]] {
        guard let data = json?.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array
    }

    private static func keyed(_ rows: Any?, idKey: String, columns: [String]) throws -> OracleValue {
        var result: [String: OracleValue] = [:]
        for row in try OracleJSON.objects(rows, idKey) {
            result[try OracleJSON.string(row, idKey)] = .object(
                try Dictionary(uniqueKeysWithValues: columns.map { ($0, try OracleValue(json: row[$0] ?? NSNull())) })
            )
        }
        return .object(result)
    }

    nonisolated private static func keyed(_ rows: [Row], idKey: String, columns: [String]) -> OracleValue {
        var result: [String: OracleValue] = [:]
        for row in rows {
            let id: String = row[idKey] ?? ""
            result[id] = .object(Dictionary(uniqueKeysWithValues: columns.map {
                ($0, OracleValue.databaseValue((row[$0] as DatabaseValue)))
            }))
        }
        return .object(result)
    }

    /// One summary per schedule rule: the payee and account references, and the date and amount conditions decoded
    /// the way production decodes them (key order, `type` and default fields do not matter).
    private static func ruleSummaries(_ rules: [(conditions: [[String: Any]], actions: [[String: Any]])]) throws -> OracleValue {
        var result: [String: OracleValue] = [:]
        for rule in rules {
            guard let link = rule.actions.first(where: { $0["op"] as? String == "link-schedule" }),
                  let scheduleID = link["value"] as? String else { continue }
            var summary: [String: OracleValue] = [:]
            for condition in rule.conditions {
                let field = condition["field"] as? String ?? ""
                let decoded = try ruleCondition(field: field, op: condition["op"] as? String ?? "", value: condition["value"] ?? NSNull())
                switch field {
                case "payee", "description":
                    summary["payee"] = try OracleValue(json: condition["value"] ?? NSNull())
                case "account", "acct":
                    summary["account"] = try OracleValue(json: condition["value"] ?? NSNull())
                case "amount":
                    summary["amount"] = .string("\(ScheduleRuleProjection.amount(from: decoded))")
                case "date":
                    summary["date"] = .string("\(ScheduleRuleProjection.dateRule(from: decoded))")
                default:
                    break
                }
            }
            result[scheduleID] = .object(summary)
        }
        return .object(result)
    }

    // MARK: Seeding

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ScheduleOracleReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeDatabase(in directory: URL) async throws -> BudgetDatabase {
        let url = directory.appending(path: "db.sqlite")
        return try await OracleReplayDatabase.starter(at: url, localNodeID: "node1")
    }

    /// Account and payee ids as the fixture normalized them, found through each schedule's rule.
    private static func referencedIDs(
        setup: [String: Any],
        before: [String: Any]
    ) throws -> (accounts: [String: String], payees: [String: String]) {
        let schedules = try OracleJSON.objects(before["schedules"], "before.schedules")
        let rules = try OracleJSON.objects(before["rules"], "before.rules")
        var accounts: [String: String] = [:]
        var payees: [String: String] = [:]
        for definition in try OracleJSON.objects(setup["schedules"], "setup.schedules") {
            let key = try OracleJSON.string(definition, "key")
            guard let row = schedules.first(where: { $0["id"] as? String == "schedule-\(key)" }),
                  let rule = rules.first(where: { $0["id"] as? String == row["rule"] as? String }) else { continue }
            for condition in rule["conditions"] as? [[String: Any]] ?? [] {
                switch condition["field"] as? String {
                case "acct", "account": accounts[try OracleJSON.string(definition, "accountKey")] = condition["value"] as? String
                case "description", "payee":
                    if let payeeKey = definition["payeeKey"] as? String { payees[payeeKey] = condition["value"] as? String }
                default: break
                }
            }
        }
        return (accounts, payees)
    }

    private struct SeedRow: Sendable {
        let sql: String
        let values: [DatabaseValue]
    }

    private static func seed(
        _ database: BudgetDatabase,
        setup: [String: Any],
        before: [String: Any],
        includingSchedules: Bool = true
    ) async throws {
        let ids = try referencedIDs(setup: setup, before: before)
        var rows: [SeedRow] = []

        func insert(_ table: String, _ row: [String: Any]) throws {
            let columns = row.keys.sorted()
            rows.append(SeedRow(
                sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
                values: try columns.map { try databaseValue(row[$0] ?? NSNull(), column: "\(table).\($0)") }
            ))
        }

        for (index, account) in try OracleJSON.objects(setup["accounts"], "setup.accounts").enumerated() {
            guard let id = ids.accounts[try OracleJSON.string(account, "key")] else { continue }
            try insert("accounts", [
                "id": id, "name": account["name"] ?? "", "offbudget": account["offbudget"] as? Bool == true ? 1 : 0,
                "closed": account["closed"] as? Bool == true ? 1 : 0, "tombstone": 0, "sort_order": index,
            ])
        }
        for payee in try OracleJSON.objects(setup["payees"], "setup.payees") {
            guard let id = ids.payees[try OracleJSON.string(payee, "key")] else { continue }
            try insert("payees", ["id": id, "name": payee["name"] ?? "", "tombstone": 0])
            try insert("payee_mapping", ["id": id, "targetId": id])
        }
        if let length = setup["upcomingLength"] as? String {
            try insert("preferences", ["id": "upcomingScheduledTransactionLength", "value": length])
        }
        if includingSchedules {
            for rule in try OracleJSON.objects(before["rules"], "before.rules") {
                var row = rule
                row["conditions"] = try jsonText(rule["conditions"])
                row["actions"] = try jsonText(rule["actions"])
                try insert("rules", row)
            }
            for schedule in try OracleJSON.objects(before["schedules"], "before.schedules") {
                try insert("schedules", schedule)
            }
            for next in try OracleJSON.objects(before["nextDates"], "before.nextDates") {
                var row = next
                let localEffective = row.removeValue(forKey: "localIsEffective") as? Bool ?? true
                row["base_next_date_ts"] = 1000
                row["local_next_date_ts"] = localEffective ? 1000 : 999
                try insert("schedules_next_date", row)
            }
            for path in try OracleJSON.objects(before["paths"], "before.paths") {
                try insert("schedules_json_paths", path)
            }
            for transaction in try OracleJSON.objects(before["transactions"], "before.transactions") {
                try insert("transactions", transaction)
            }
        }

        let queue = await database.queue
        let insertions = rows
        try await queue.write { db in
            for table in ["accounts", "payees", "payee_mapping", "preferences", "rules", "schedules", "schedules_next_date",
                          "schedules_json_paths", "transactions"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            for row in insertions {
                try db.execute(sql: row.sql, arguments: StatementArguments(row.values as [any DatabaseValueConvertible]))
            }
        }
    }

    private static func jsonText(_ value: Any?) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value ?? [], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func databaseValue(_ value: Any, column: String) throws -> DatabaseValue {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return string.databaseValue
        case let number as NSNumber:
            if String(cString: number.objCType) == "d" { return number.doubleValue.databaseValue }
            return number.int64Value.databaseValue
        default:
            throw OracleReplayError.malformedFixture("unsupported value in \(column)")
        }
    }
}
