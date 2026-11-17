import Foundation
import GRDB

enum BudgetModeSQL {
    /// This local-only UUID identifies an imported database, not its budget mode.
    /// Reopening preserves it; replacing the imported file creates a new identity.
    static func prepareBudgetIdentity(in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS actualist_budget_identity (
                    id INTEGER PRIMARY KEY CHECK (id = 1), storage_id TEXT NOT NULL
                )
                """)
            try db.execute(sql: "INSERT OR IGNORE INTO actualist_budget_identity VALUES (1, ?)",
                arguments: [UUID().uuidString])
        }
    }

    static func fetchBudgetModeIdentity(in database: isolated BudgetDatabase) throws -> BudgetModeIdentity {
        try database.queue.read { db in try budgetModeIdentity(in: database, db: db) }
    }

    static func requireBudgetMode(_ expected: BudgetModeIdentity?, in database: isolated BudgetDatabase) throws -> BudgetModeIdentity {
        let current = try fetchBudgetModeIdentity(in: database)
        if let expected, expected != current { throw BudgetModeWriteError.budgetChanged }
        return current
    }

    static func budgetModeIdentity(in database: isolated BudgetDatabase, db: Database) throws -> BudgetModeIdentity {
        guard let storageID = try String.fetchOne(db,
            sql: "SELECT storage_id FROM actualist_budget_identity WHERE id = 1") else {
            throw LocalFirstError.invalidDownloadedBudget
        }
        let revision: String?
        if try database.tableExists("messages_crdt", db: db) {
            revision = try String.fetchOne(db, sql: """
                SELECT MAX(timestamp) FROM messages_crdt
                WHERE dataset = 'preferences' AND row = 'budgetType' AND column = 'value'
                """)
        } else {
            revision = nil
        }
        return BudgetModeIdentity(storageID: storageID, table: try database.budgetTable(db: db), revision: revision)
    }

    static func validateBudgetWrite(
        _ drafts: [ActualSyncDecodedMessage],
        expectedMode: BudgetModeIdentity?,
        descriptor: BudgetActionDescriptor?,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let budgetDrafts = drafts.filter { BudgetTable(rawValue: $0.dataset) != nil }
        guard expectedMode != nil || !budgetDrafts.isEmpty else { return }
        let current = try budgetModeIdentity(in: database, db: db)
        if let expectedMode, expectedMode != current { throw BudgetModeWriteError.budgetChanged }
        guard budgetDrafts.allSatisfy({ $0.dataset == current.table.rawValue }) else {
            throw BudgetModeWriteError.budgetChanged
        }
        if case .move = descriptor,
           !BudgetActionEligibility.allows(.moveMoney, in: current.table) {
            throw BudgetModeWriteError.unsupportedAction
        }
        for draft in budgetDrafts where draft.column == "amount" {
            if case .int(let amount) = try ActualSyncSQLiteValue(serialized: draft.serializedValue) {
                guard let value = Int(exactly: amount),
                      (-Money.maximumUserAmountMinorUnits...Money.maximumUserAmountMinorUnits).contains(value) else {
                    throw LocalFirstError.numericValueOutOfRange
                }
                _ = try BudgetFinancialCalculation.sum([value], table: current.table)
            }
        }
        guard current.table == .tracking else { return }
        let incomeByID = try TemplateCategorySQL.templateCategoryIsIncomeByID(in: database, db: db)
        for draft in budgetDrafts where draft.column == "carryover" {
            // Row creation writes carryover=false, including new income assignments.
            let value = try ActualSyncSQLiteValue(serialized: draft.serializedValue)
            let explicitCarryover: Bool
            if case .carryover = descriptor { explicitCarryover = true } else { explicitCarryover = false }
            guard case .int(let flag) = value, flag != 0 || explicitCarryover else { continue }
            let categoryMessage = budgetDrafts.first { $0.row == draft.row && $0.column == "category" }
            let categoryID: String?
            if let categoryMessage, case .string(let id) = try ActualSyncSQLiteValue(serialized: categoryMessage.serializedValue) {
                categoryID = id
            } else {
                categoryID = try String.fetchOne(db,
                    sql: "SELECT category FROM reflect_budgets WHERE id = ?", arguments: [draft.row])
            }
            if categoryID.flatMap({ incomeByID[$0] }) == true {
                throw BudgetModeWriteError.unsupportedAction
            }
        }
    }
}
