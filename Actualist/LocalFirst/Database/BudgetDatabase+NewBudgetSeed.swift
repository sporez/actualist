import Foundation
import GRDB

/// Fresh-budget bootstrap. Pinned Actual `createBudget` copies its bundled
/// `default-db.sqlite` bytes; Actualist cannot ship those bytes, so this owner
/// re-projects the seed's shape into a brand-new local database instead:
/// empty Actual-compatible table shells plus the frozen starter projection
/// (three category groups, seven categories, zero accounts, zero CRDT
/// messages).
///
/// Every starter row ID is generated at runtime. Actual's seed UUIDs are
/// generator output, not stable contracts, and are never copied. The
/// projection's group and category order is the observed starter structure,
/// not an alphabetical sort; `sort_order` values are generated fresh and
/// unique across the projection because the seed's values are not unique
/// within a group and display order cannot be derived from them.
extension BudgetDatabase {
    /// Creates a new starter database at `databaseURL` and returns it opened.
    /// `identityGenerator` supplies every starter row ID; production uses
    /// UUIDs and tests pass a deterministic sequence.
    static func makeNewBudgetStarterDatabase(
        at databaseURL: URL,
        identityGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) throws -> BudgetDatabase {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: newBudgetSeedSchemaSQL)
            try insertNewBudgetStarterRows(db: db, identityGenerator: identityGenerator)
        }
        return try BudgetDatabase(databaseURL: databaseURL)
    }

    // Table shells matching the layout the app reads and writes — the same
    // shape the demo-budget generator commits, which the sync-apply layer and
    // every database read accept. Sync apply skips unknown datasets, so a
    // fresh budget needs no further tables to receive CRDT messages.
    private static let newBudgetSeedSchemaSQL = """
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            offbudget INTEGER NOT NULL DEFAULT 0,
            closed INTEGER NOT NULL DEFAULT 0,
            tombstone INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0,
            bank_sync_status TEXT,
            last_reconciled INTEGER
        );
        CREATE TABLE category_groups (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_income INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0,
            tombstone INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE categories (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            cat_group TEXT,
            is_income INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0,
            tombstone INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL DEFAULT 0,
            goal_def TEXT,
            template_settings TEXT
        );
        CREATE TABLE zero_budgets (
            month INTEGER,
            category TEXT,
            amount INTEGER NOT NULL DEFAULT 0,
            carryover INTEGER NOT NULL DEFAULT 0,
            goal INTEGER,
            long_goal INTEGER
        );
        CREATE TABLE zero_budget_months (
            id TEXT PRIMARY KEY,
            buffered INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE transactions (
            id TEXT PRIMARY KEY,
            acct TEXT,
            date INTEGER,
            amount INTEGER,
            category TEXT,
            tombstone INTEGER NOT NULL DEFAULT 0,
            parent_id TEXT,
            is_parent INTEGER NOT NULL DEFAULT 0,
            description TEXT,
            notes TEXT,
            cleared INTEGER NOT NULL DEFAULT 0,
            reconciled INTEGER NOT NULL DEFAULT 0,
            imported_description TEXT,
            sort_order REAL,
            transferred_id TEXT,
            is_child INTEGER NOT NULL DEFAULT 0,
            error TEXT
        );
        CREATE TABLE payees (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            category TEXT,
            transfer_acct TEXT,
            favorite INTEGER NOT NULL DEFAULT 0,
            tombstone INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE payee_mapping (
            id TEXT PRIMARY KEY,
            targetId TEXT
        );
        CREATE TABLE category_mapping (
            id TEXT PRIMARY KEY,
            transferId TEXT
        );
        CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            note TEXT
        );
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            conditions TEXT,
            actions TEXT,
            tombstone INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE schedules (
            id TEXT PRIMARY KEY,
            name TEXT,
            rule TEXT,
            completed INTEGER NOT NULL DEFAULT 0,
            tombstone INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE messages_crdt (
            timestamp TEXT,
            dataset TEXT,
            row TEXT,
            column TEXT,
            value TEXT
        );
        """

    // The frozen starter projection: group name, income flag, and the group's
    // categories in observed order. Deliberately not alphabetical, and the
    // category lists are not derived from the seed's shared sort_order values.
    private static let newBudgetStarterGroups: [(name: String, isIncome: Bool, categories: [String])] = [
        (name: "Usual Expenses", isIncome: false, categories: ["Food", "General", "Bills", "Bills (Flexible)"]),
        (name: "Investments and Savings", isIncome: false, categories: ["Savings"]),
        (name: "Income", isIncome: true, categories: ["Income", "Starting Balances"])
    ]

    private static func insertNewBudgetStarterRows(
        db: Database,
        identityGenerator: @Sendable () -> String
    ) throws {
        var groupOrder = 0.0
        // One continuously increasing counter, so every starter row carries a
        // distinct display order — the seed's shared `sort_order` values are
        // never reproduced.
        var categoryOrder = 0.0
        for group in newBudgetStarterGroups {
            let groupID = identityGenerator()
            groupOrder += ActualSortOrder.increment
            try db.execute(
                sql: """
                    INSERT INTO category_groups (id, name, is_income, hidden, tombstone, sort_order)
                    VALUES (?, ?, ?, 0, 0, ?)
                    """,
                arguments: [groupID, group.name, group.isIncome, groupOrder]
            )
            for categoryName in group.categories {
                let categoryID = identityGenerator()
                categoryOrder += ActualSortOrder.increment
                try db.execute(
                    sql: """
                        INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                        VALUES (?, ?, ?, ?, 0, 0, ?)
                        """,
                    arguments: [categoryID, categoryName, groupID, group.isIncome, categoryOrder]
                )
            }
        }
    }
}
