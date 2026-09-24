import Foundation
import GRDB
@testable import Actualist

enum TransactionStatusFilterTestSupport {
    static func database() throws -> BudgetDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistTransactionStatusFilters-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: schema(includeStatusColumns: true))
            try db.execute(sql: baseFixtureSQL)
            try db.execute(sql: splitAndCategoryFixtureSQL)
            try db.execute(sql: sourceAndTransferFixtureSQL)
            try db.execute(sql: searchFixtureSQL)
        }
        return try BudgetDatabase(databaseURL: url)
    }

    static func legacyDatabaseWithoutStatusColumns() throws -> BudgetDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistLegacyTransactionStatus-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: schema(includeStatusColumns: false))
            try db.execute(sql: """
                INSERT INTO transactions (
                    id, isParent, isChild, acct, category, amount, description, date, tombstone
                ) VALUES ('legacy-no-status', 0, 0, 'checking', NULL, -100, 'coffee', 20260830, 0);
                """)
        }
        return try BudgetDatabase(databaseURL: url)
    }

    static func appendTransactions(
        count: Int,
        prefix: String,
        to database: BudgetDatabase
    ) async throws {
        let queue = try DatabaseQueue(path: (await database.databaseURL).path)
        try await queue.write { db in
            for index in 0..<count {
                try db.execute(
                    sql: """
                        INSERT INTO transactions (
                            id, isParent, isChild, acct, category, amount, description, notes,
                            date, sort_order, tombstone, parent_id, cleared, reconciled
                        ) VALUES (?, 0, 0, 'checking', 'groceries', -100, 'coffee', 'feed pagination',
                                  20260831, ?, 0, NULL, 0, 0)
                        """,
                    arguments: ["\(prefix)-\(index)", 20_000 - index]
                )
            }
        }
    }

    private static func schema(includeStatusColumns: Bool) -> String {
        let statusColumns = includeStatusColumns
            ? "cleared INTEGER, reconciled INTEGER,"
            : ""
        return """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, offbudget INTEGER,
                closed INTEGER, tombstone INTEGER, sort_order INTEGER
            );
            CREATE TABLE category_groups (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, is_income INTEGER,
                hidden INTEGER, tombstone INTEGER, sort_order INTEGER
            );
            CREATE TABLE categories (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, cat_group TEXT,
                is_income INTEGER, hidden INTEGER, tombstone INTEGER, sort_order INTEGER
            );
            CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT);
            CREATE TABLE payees (
                id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER
            );
            CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
            CREATE TABLE transactions (
                id TEXT PRIMARY KEY, isParent INTEGER DEFAULT 0, isChild INTEGER DEFAULT 0,
                acct TEXT, category TEXT, amount INTEGER, description TEXT, notes TEXT,
                date INTEGER, sort_order REAL, tombstone INTEGER DEFAULT 0,
                parent_id TEXT, starting_balance_flag INTEGER DEFAULT 0,
                transferred_id TEXT, \(statusColumns) error TEXT
            );
            INSERT INTO accounts VALUES
                ('checking', 'Checking', 0, 0, 0, 1),
                ('savings', 'Savings', 0, 0, 0, 2),
                ('tracking', 'Tracking', 1, 0, 0, 3);
            INSERT INTO category_groups VALUES ('group', 'Everyday', 0, 0, 0, 1);
            INSERT INTO categories VALUES ('groceries', 'Groceries', 'group', 0, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('groceries', 'groceries');
            INSERT INTO category_mapping VALUES ('raw-category', NULL);
            INSERT INTO category_mapping VALUES ('empty-mapped-category', '');
            INSERT INTO payees VALUES
                ('coffee', 'Coffee Shop', NULL, 0),
                ('xfer-checking', '', 'checking', 0),
                ('xfer-savings', '', 'savings', 0),
                ('xfer-tracking', '', 'tracking', 0);
            INSERT INTO payee_mapping VALUES
                ('coffee', 'coffee'),
                ('xfer-checking', 'xfer-checking'),
                ('xfer-savings', 'xfer-savings'),
                ('xfer-tracking', 'xfer-tracking');
            """
    }

    private static var baseFixtureSQL: String {
        """
        INSERT INTO transactions (
            id, isParent, isChild, acct, category, amount, description, notes,
            date, sort_order, tombstone, parent_id, cleared, reconciled
        ) VALUES
        ('status-neither', 0, 0, 'checking', 'groceries', -100, 'coffee', NULL, 20260830, 1000, 0, NULL, 0, 0),
        ('status-cleared', 0, 0, 'checking', 'groceries', -200, 'coffee', NULL, 20260829, 990, 0, NULL, 1, 0),
        ('status-reconciled', 0, 0, 'checking', 'groceries', -300, 'coffee', NULL, 20260828, 980, 0, NULL, 1, 1),
        ('status-reconciled-uncleared', 0, 0, 'checking', 'groceries', -400, 'coffee', NULL, 20260827, 970, 0, NULL, 0, 1),
        ('status-null', 0, 0, 'checking', 'groceries', -500, 'coffee', NULL, 20260826, 960, 0, NULL, NULL, NULL),
        ('mapped-null-target', 0, 0, 'checking', 'raw-category', -600, 'coffee', NULL, 20260825, 950, 0, NULL, 0, 0),
        ('mapped-empty-target', 0, 0, 'checking', 'empty-mapped-category', -700, 'coffee', NULL, 20260824, 940, 0, NULL, 0, 0),
        ('unknown-source-account', 0, 0, 'unlisted-account', NULL, -800, 'coffee', NULL, 20260823, 930, 0, NULL, 0, 0),
        ('other-account-row', 0, 0, 'savings', 'groceries', -900, 'coffee', NULL, 20260822, 920, 0, NULL, 0, 0);
        """
    }

    private static var splitAndCategoryFixtureSQL: String {
        """
        INSERT INTO transactions (
            id, isParent, isChild, acct, category, amount, description, notes,
            date, sort_order, tombstone, parent_id, cleared, reconciled
        ) VALUES
        ('mixed-parent', 1, 0, 'checking', NULL, -3000, NULL, 'split parent', 20260821, 910, 0, NULL, 1, 0),
        ('mixed-uncategorized-child', 0, 1, 'checking', NULL, -1000, 'coffee', 'mixed uncategorized search needle', 20260821, 909, 0, 'mixed-parent', 0, 0),
        ('mixed-categorized-child', 0, 1, 'checking', 'groceries', -2000, 'coffee', NULL, 20260821, 908, 0, 'mixed-parent', 1, 1),
        ('mixed-tombstoned-child', 0, 1, 'checking', NULL, -500, 'coffee', NULL, 20260821, 907, 1, 'mixed-parent', 0, 0),
        ('categorized-only-parent', 1, 0, 'checking', NULL, -1200, NULL, 'categorized children', 20260814, 845, 0, NULL, 1, 0),
        ('categorized-only-child', 0, 1, 'checking', 'groceries', -1200, 'coffee', NULL, 20260814, 844, 0, 'categorized-only-parent', 0, 0),
        ('dead-only-parent', 1, 0, 'checking', NULL, -700, NULL, 'dead child only', 20260813, 840, 0, NULL, 1, 0),
        ('dead-only-child', 0, 1, 'checking', NULL, -700, 'coffee', NULL, 20260813, 839, 1, 'dead-only-parent', 0, 0),
        ('dead-parent', 1, 0, 'checking', NULL, -1000, NULL, 'dead', 20260820, 900, 1, NULL, 0, 0),
        ('orphan-of-dead-parent', 0, 1, 'checking', NULL, -1000, 'coffee', NULL, 20260820, 899, 0, 'dead-parent', 0, 0),
        ('uncategorized-tombstone', 0, 0, 'checking', NULL, -1000, 'coffee', NULL, 20260819, 890, 1, NULL, 0, 0);
        """
    }

    private static var sourceAndTransferFixtureSQL: String {
        """
        INSERT INTO transactions (
            id, isParent, isChild, acct, category, amount, description, notes,
            date, sort_order, tombstone, parent_id, cleared, reconciled
        ) VALUES
        ('ordinary-uncategorized', 0, 0, 'checking', NULL, -1100, 'coffee', NULL, 20260818, 880, 0, NULL, 0, 0),
        ('offbudget-source', 0, 0, 'tracking', NULL, -1200, 'coffee', NULL, 20260817, 870, 0, NULL, 0, 0),
        ('onbudget-transfer', 0, 0, 'checking', NULL, -1300, 'xfer-savings', NULL, 20260816, 860, 0, NULL, 0, 0),
        ('offbudget-destination-transfer', 0, 0, 'checking', NULL, -1400, 'xfer-tracking', NULL, 20260815, 850, 0, NULL, 0, 0);
        """
    }

    private static var searchFixtureSQL: String {
        (0..<53).map { index in
            let id = String(format: "search-match-%03d", index)
            let order = 800 - (index * 2)
            let match = "INSERT INTO transactions (id, isParent, isChild, acct, category, amount, description, notes, date, sort_order, tombstone, parent_id, cleared, reconciled) VALUES ('\(id)', 0, 0, 'checking', 'groceries', -100, 'coffee', 'status-search-needle', 20260810, \(order), 0, NULL, 0, 0);"
            let decoy = "INSERT INTO transactions (id, isParent, isChild, acct, category, amount, description, notes, date, sort_order, tombstone, parent_id, cleared, reconciled) VALUES ('search-decoy-\(String(format: "%03d", index))', 0, 0, 'checking', 'groceries', -100, 'coffee', 'status-search-decoy', 20260810, \(order - 1), 0, NULL, 0, 0);"
            return "\(match)\n\(decoy)"
        }.joined(separator: "\n")
    }
}
