import Foundation
import GRDB
import Testing
@testable import Actualist

/// `PayeeSQL`'s `payee_mapping` readers replace six hand-written copies. Each
/// test reads every schema variant through the owner and through a verbatim
/// copy of the code it replaced, and requires the same result.
struct PayeeMappingReadTests {
    enum Variant: String, CaseIterable, Sendable {
        case noTable
        case noTarget
        case noID
        case targetId
        case target_id
        case bothTargets

        var sql: String {
            let rows = "('a', 'b'), ('b', 'c'), ('c', 'c'), ('n', NULL)"
            switch self {
            case .noTable:
                return "CREATE TABLE unrelated (x TEXT);"
            case .noTarget:
                return """
                    CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, other TEXT);
                    INSERT INTO payee_mapping VALUES ('a', 'x');
                    """
            case .noID:
                return """
                    CREATE TABLE payee_mapping (mid TEXT PRIMARY KEY, targetId TEXT);
                    INSERT INTO payee_mapping VALUES ('a', 'b');
                    """
            case .targetId:
                return """
                    CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
                    INSERT INTO payee_mapping VALUES \(rows);
                    """
            case .target_id:
                return """
                    CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, target_id TEXT);
                    INSERT INTO payee_mapping VALUES \(rows);
                    """
            case .bothTargets:
                return """
                    CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT, target_id TEXT);
                    INSERT INTO payee_mapping VALUES ('a', 'b', 'x'), ('b', 'c', 'y');
                    """
            }
        }
    }

    private func read<T: Sendable>(
        _ database: isolated BudgetDatabase,
        _ body: @Sendable (isolated BudgetDatabase, Database) throws -> T
    ) throws -> T {
        try database.queue.read { db in try body(database, db) }
    }

    private func makeDatabase(_ variant: Variant) async throws -> BudgetDatabase {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ActualistPayeeMapping-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in try db.execute(sql: variant.sql) }
        return try BudgetDatabase(databaseURL: url)
    }

    @Test(arguments: Variant.allCases)
    func ownerReadsWhatEachReplacedCopyRead(variant: Variant) async throws {
        let database = try await makeDatabase(variant)
        let result = try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            let targets = try PayeeSQL.payeeMappingTargets(in: database, db: db)
            let usable = try PayeeSQL.usablePayeeMappingColumns(in: database, db: db)
            let rows = try PayeeSQL.payeeMappingRows(in: database, db: db).map { [$0.id, $0.target] }
            return (
                targets: targets,
                ruleTargets: try Self.ruleTargetsDeletedCopy(in: database, db: db),
                scheduleTargets: try Self.scheduleTargetsDeletedCopy(in: database, db: db),
                usable: usable.map { [$0.id, $0.target] },
                managementUsable: try Self.managementUsableDeletedCopy(in: database, db: db).map { [$0.id, $0.target] },
                rows: rows,
                batchRows: try Self.batchRowsDeletedCopy(in: database, db: db),
                managementRows: try Self.managementRowsDeletedCopy(in: database, db: db),
                joinTarget: usable?.target,
                oldJoinTarget: try Self.joinTargetDeletedCopy(in: database, db: db)
            )
        }
        #expect(result.targets == result.ruleTargets)
        #expect(result.targets == result.scheduleTargets)
        #expect(result.usable == result.managementUsable)
        #expect(result.rows == result.batchRows)
        #expect(result.rows == result.managementRows)
        #expect(result.joinTarget == result.oldJoinTarget)
    }

    @Test func batchLoopGivesTheSameNamesWhenRowsReadEarlierRows() async throws {
        let database = try await makeDatabase(.targetId)
        let initial = ["a": "", "b": "Bee", "c": "Sea"]
        let result = try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            var old = initial
            if try database.tableExists("payee_mapping", db: db) {
                let columns = try database.columnSet(for: "payee_mapping", db: db)
                let target = columns.contains("targetId")
                    ? "targetId"
                    : columns.contains("target_id") ? "target_id" : nil
                if columns.contains("id"), let target {
                    let rows = try Row.fetchAll(
                        db,
                        sql: "SELECT id, \(database.quotedIdentifier(target)) AS target_id FROM payee_mapping"
                    )
                    for row in rows {
                        guard let aliasID = row["id"] as String?,
                              let targetID = row["target_id"] as String?,
                              let targetName = Self.nonemptyBatchName(old[targetID]) else { continue }
                        old[aliasID] = targetName
                    }
                }
            }
            var new = initial
            for mapping in try PayeeSQL.payeeMappingRows(in: database, db: db) {
                guard let targetName = Self.nonemptyBatchName(new[mapping.target]) else { continue }
                new[mapping.id] = targetName
            }
            return (old, new)
        }
        #expect(result.0 == result.1)
        #expect(result.1["a"] == "Bee")
    }

    // MARK: Verbatim copies of the code the owner replaced

    private static func nonemptyBatchName(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// `RuleSQL.payeeMappingTargets`.
    private static func ruleTargetsDeletedCopy(in database: isolated BudgetDatabase, db: Database) throws -> [String: String] {
        guard try database.tableExists("payee_mapping", db: db) else { return [:] }
        let columns = try database.columnSet(for: "payee_mapping", db: db)
        guard columns.contains("id") else { return [:] }
        let target = columns.contains("targetId") ? "targetId" : columns.contains("target_id") ? "target_id" : nil
        guard let target else { return [:] }
        let rows = try Row.fetchAll(db, sql: "SELECT id, \(database.quotedIdentifier(target)) AS target_id FROM payee_mapping")
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["id"] as String?, let targetID = row["target_id"] as String? else { return nil }
            return (id, targetID)
        })
    }

    /// `ScheduleSQL.schedulePayeeTargets`.
    private static func scheduleTargetsDeletedCopy(in database: isolated BudgetDatabase, db: Database) throws -> [String: String] {
        guard try database.tableExists("payee_mapping", db: db) else { return [:] }
        let columns = try database.columnSet(for: "payee_mapping", db: db)
        guard columns.contains("id") else { return [:] }
        let target: String
        if columns.contains("targetId") { target = "targetId" }
        else if columns.contains("target_id") { target = "target_id" }
        else { return [:] }
        let rows = try Row.fetchAll(db, sql: "SELECT id, \(target) AS target_id FROM payee_mapping")
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = row["id"] as String?, let target = row["target_id"] as String? else { return nil }
            return (id, target)
        })
    }

    /// `PayeeManagementSQL.usablePayeeMappingColumns`.
    private static func managementUsableDeletedCopy(
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (id: String, target: String)? {
        guard try database.tableExists("payee_mapping", db: db) else {
            return nil
        }
        let columns = try database.columnSet(for: "payee_mapping", db: db)
        guard columns.contains("id") else {
            return nil
        }
        if columns.contains("targetId") {
            return ("id", "targetId")
        }
        if columns.contains("target_id") {
            return ("id", "target_id")
        }
        return nil
    }

    /// The block `BudgetDatabase+TransactionBatch` ran, collecting the pairs its loop read.
    private static func batchRowsDeletedCopy(in database: isolated BudgetDatabase, db: Database) throws -> [[String]] {
        var collected: [[String]] = []
        if try database.tableExists("payee_mapping", db: db) {
            let columns = try database.columnSet(for: "payee_mapping", db: db)
            let target = columns.contains("targetId")
                ? "targetId"
                : columns.contains("target_id") ? "target_id" : nil
            if columns.contains("id"), let target {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, \(database.quotedIdentifier(target)) AS target_id FROM payee_mapping"
                )
                for row in rows {
                    guard let aliasID = row["id"] as String?,
                          let targetID = row["target_id"] as String? else { continue }
                    collected.append([aliasID, targetID])
                }
            }
        }
        return collected
    }

    /// The `PayeeManagementSQL` loops: usable columns, then the full query, both ids required.
    private static func managementRowsDeletedCopy(in database: isolated BudgetDatabase, db: Database) throws -> [[String]] {
        var collected: [[String]] = []
        if let mapping = try managementUsableDeletedCopy(in: database, db: db) {
            let mappingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(database.quotedIdentifier(mapping.id)) AS id,
                           \(database.quotedIdentifier(mapping.target)) AS target_id
                    FROM payee_mapping
                    """
            )
            for row in mappingRows {
                guard let id = row["id"] as String?, let target = row["target_id"] as String? else { continue }
                collected.append([id, target])
            }
        }
        return collected
    }

    /// The detection `RuleSQL.categoryLearningRuleMessages` and `PayeeSQL.recentCommonPayeeRanks` ran inline.
    private static func joinTargetDeletedCopy(in database: isolated BudgetDatabase, db: Database) throws -> String? {
        if try database.tableExists("payee_mapping", db: db) {
            let mappingColumns = try database.columnSet(for: "payee_mapping", db: db)
            let target = mappingColumns.contains("targetId") ? "targetId" : mappingColumns.contains("target_id") ? "target_id" : nil
            if mappingColumns.contains("id"), let target {
                return target
            }
        }
        return nil
    }
}
