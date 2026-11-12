import Foundation
import GRDB
import Testing
@testable import Actualist

/// Pins what the three transaction row loaders read from the same stored row,
/// including where they differ (Decision Register D1, D10, D13). The loaders
/// are the split family record, the batch snapshot and the undo snapshot.
@MainActor
struct TransactionRowLoaderCharacterizationTests {
    private let support = LocalFirstActualStoreTests()

    private func read<T: Sendable>(
        _ database: isolated BudgetDatabase,
        _ body: @Sendable (isolated BudgetDatabase, Database) throws -> T
    ) throws -> T {
        try database.queue.read { db in try body(database, db) }
    }

    private struct Loaded: Sendable {
        let split: SplitTransactionRecord?
        let batch: TransactionBatchTransactionSnapshot?
        let undo: TransactionUndoSnapshot?
        let columns: [String]
    }

    private func loadAll(_ database: BudgetDatabase, ids: [String]) async throws -> [String: Loaded] {
        try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            let columns = try database.resolveTransactionRowColumns(db: db)
            var output: [String: Loaded] = [:]
            for id in ids {
                output[id] = Loaded(
                    split: try database.loadTransactionRecord(id: id, columns: columns, db: db),
                    batch: try database.transactionBatchSnapshot(id: id, columns: columns, db: db),
                    undo: try database.transactionUndoSnapshot(id: id, db: db),
                    columns: columns.all.sorted()
                )
            }
            return output
        }
    }

    // MARK: Every storage type, read through each loader

    /// SQL literal for each stored value. The columns are untyped, so SQLite
    /// keeps each value in the storage class it was written with.
    ///
    /// Only the split loader reads a boolean without decoding it as a number
    /// first, so only it survives every storage class. The batch and undo
    /// loaders used to decode a number with `row[column] as Int?`, which trapped
    /// on text and blobs (GRDB `try!`). `textAndBlobCellsReadWithoutTrappingInBatchAndUndo`
    /// pins them over the other classes.
    private static let allProbes: [(label: String, literal: String)] = [
        ("null", "NULL"), ("0", "0"), ("1", "1"), ("2", "2"), ("-1", "-1"),
        ("max", "9223372036854775807"),
        ("0.0", "0.0"), ("1.0", "1.0"), ("1.5", "1.5"),
        ("'0'", "'0'"), ("'1'", "'1'"), ("'2'", "'2'"),
        ("'true'", "'true'"), ("'false'", "'false'"), ("'yes'", "'yes'"), ("'no'", "'no'"),
        ("'TRUE'", "'TRUE'"), ("' 1 '", "' 1 '"), ("''", "''"), ("'abc'", "'abc'"),
        ("blob 'true'", "X'74727565'"), ("blob '1'", "X'31'"), ("blob ff", "X'00FF'"),
    ]
    private static let numericLabels: Set<String> = ["null", "0", "1", "2", "-1", "max", "0.0", "1.0", "1.5"]

    // Split record booleans: `flexibleBool` on the raw value. A REAL is false.
    private static let splitBool: Set<String> = ["1", "2", "-1", "max", "'1'", "'true'", "'yes'", "'TRUE'"]
    // Undo booleans and amounts: `row[column] as Int?`. A REAL truncates toward zero.
    private static let undoInt: [String: Int] = [
        "0": 0, "1": 1, "2": 2, "-1": -1, "max": Int.max, "0.0": 0, "1.0": 1, "1.5": 1,
    ]
    // Batch flag (D13): a non-zero integer. Unknown text would be nil, but the
    // integer read traps first.
    private static let batchFlag: [String: Bool] = [
        "0": false, "1": true, "2": true, "-1": true, "max": true, "0.0": false, "1.0": true, "1.5": true,
    ]
    // Sort order: a stored number.
    private static let sortOrder: [String: Double] = [
        "0": 0, "1": 1, "2": 2, "-1": -1, "max": Double(Int64.max), "0.0": 0, "1.0": 1, "1.5": 1.5,
    ]

    private func insertSQL(_ probes: [(label: String, literal: String)], amount: Bool, sort: Bool) -> String {
        var inserts = ""
        for (index, probe) in probes.enumerated() {
            let v = probe.literal
            inserts += """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, reconciled, sort_order, description)
                    VALUES ('p\(index)', 'checking', 20260703, \(amount ? v : "-1250"), 'groceries', \(v), NULL, \(v), \(v), \(v), \(sort ? v : "NULL"), NULL);

                """
        }
        return """
            DROP TABLE transactions;
            CREATE TABLE transactions (
                id TEXT PRIMARY KEY, acct, date, amount, category, tombstone, parent_id,
                is_parent, cleared, reconciled, sort_order, description
            );
            \(inserts)
            """
    }

    @Test func splitRecordReadsEveryStorageTypeAsABoolean() async throws {
        let probes = Self.allProbes
        let database = try BudgetDatabase(
            databaseURL: support.makeSQLiteFixture(extraSQL: insertSQL(probes, amount: false, sort: false))
        )
        let splits = try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            let columns = try database.resolveTransactionRowColumns(db: db)
            return try probes.indices.map {
                try database.loadTransactionRecord(id: "p\($0)", columns: columns, db: db)
            }
        }
        for (index, probe) in probes.enumerated() {
            let flag = Self.splitBool.contains(probe.label)
            #expect(splits[index] == SplitTransactionRecord(
                id: "p\(index)",
                amount: -1250,
                account: "checking",
                date: "2026-07-03",
                category: "groceries",
                payee: nil,
                notes: nil,
                cleared: flag,
                reconciled: flag,
                startingBalance: nil,
                sortOrder: nil,
                isParent: flag,
                isChild: false,
                parentID: nil,
                transferID: nil,
                error: nil,
                deleted: flag
            ), "split \(probe.label)")
        }
    }

    @Test func eachNumericStorageTypeReadsAsPinnedByEveryLoader() async throws {
        let probes = Self.allProbes.filter { Self.numericLabels.contains($0.label) }
        let database = try BudgetDatabase(
            databaseURL: support.makeSQLiteFixture(extraSQL: insertSQL(probes, amount: true, sort: true))
        )
        let loaded = try await loadAll(database, ids: probes.indices.map { "p\($0)" })

        for (index, probe) in probes.enumerated() {
            let label = probe.label
            let row = try #require(loaded["p\(index)"], "\(label)")
            let splitBool = Self.splitBool.contains(label)
            let undoBool = (Self.undoInt[label] ?? 0) != 0

            let split = try #require(row.split, "\(label)")
            #expect(split == SplitTransactionRecord(
                id: "p\(index)",
                amount: Self.undoInt[label] ?? 0,
                account: "checking",
                date: "2026-07-03",
                category: "groceries",
                payee: nil,
                notes: nil,
                cleared: splitBool,
                reconciled: splitBool,
                startingBalance: nil,
                sortOrder: Self.sortOrder[label],
                isParent: splitBool,
                isChild: false,
                parentID: nil,
                transferID: nil,
                error: nil,
                deleted: splitBool
            ), "split \(label)")

            let batch = try #require(row.batch, "\(label)")
            #expect(batch == TransactionBatchTransactionSnapshot(
                id: "p\(index)",
                columns: row.columns,
                accountID: "checking",
                dateValue: 20_260_703,
                amount: Self.undoInt[label],
                payeeID: nil,
                categoryID: "groceries",
                notes: nil,
                cleared: Self.batchFlag[label],
                reconciled: Self.batchFlag[label],
                tombstone: Self.batchFlag[label],
                isParent: Self.batchFlag[label],
                isChild: false,
                parentID: nil,
                transferID: nil,
                sortOrder: Self.sortOrder[label],
                splitError: nil,
                startingBalance: nil,
                scheduleID: nil,
                importedID: nil,
                importedPayee: nil,
                importedDescription: nil
            ), "batch \(label)")

            let undo = try #require(row.undo, "\(label)")
            #expect(undo == TransactionUndoSnapshot(
                id: "p\(index)",
                accountID: "checking",
                dateValue: 20_260_703,
                amount: Self.undoInt[label] ?? 0,
                payeeID: nil,
                categoryID: "groceries",
                notes: nil,
                cleared: undoBool,
                tombstone: undoBool,
                transferID: nil,
                isParent: undoBool,
                isChild: false,
                parentID: nil
            ), "undo \(label)")
        }
    }

    /// Text, blob and out-of-range REAL cells in the number columns. They used
    /// to trap inside GRDB (Decision Register D14); now numeric text reads as
    /// the number and everything else as no value.
    @Test func textAndBlobCellsReadWithoutTrappingInBatchAndUndo() async throws {
        struct Expected {
            let int: Int?
            let flag: Bool?
            let sort: Double?
        }
        let cases: [(label: String, literal: String, expected: Expected)] = [
            ("'0'", "'0'", Expected(int: 0, flag: false, sort: 0)),
            ("'1'", "'1'", Expected(int: 1, flag: true, sort: 1)),
            ("'2'", "'2'", Expected(int: 2, flag: true, sort: 2)),
            ("'1.5'", "'1.5'", Expected(int: nil, flag: nil, sort: 1.5)),
            ("'true'", "'true'", Expected(int: nil, flag: true, sort: nil)),
            ("'FALSE'", "'FALSE'", Expected(int: nil, flag: false, sort: nil)),
            ("'yes'", "'yes'", Expected(int: nil, flag: true, sort: nil)),
            ("'no'", "'no'", Expected(int: nil, flag: false, sort: nil)),
            ("' 1 '", "' 1 '", Expected(int: nil, flag: nil, sort: nil)),
            ("''", "''", Expected(int: nil, flag: nil, sort: nil)),
            ("'abc'", "'abc'", Expected(int: nil, flag: nil, sort: nil)),
            ("blob '1'", "X'31'", Expected(int: nil, flag: nil, sort: nil)),
            ("blob ff", "X'00FF'", Expected(int: nil, flag: nil, sort: nil)),
            ("1e300", "1e300", Expected(int: nil, flag: nil, sort: 1e300)),
            ("-1e300", "-1e300", Expected(int: nil, flag: nil, sort: -1e300)),
        ]
        let probes = cases.map { (label: $0.label, literal: $0.literal) }
        let database = try BudgetDatabase(
            databaseURL: support.makeSQLiteFixture(extraSQL: insertSQL(probes, amount: true, sort: true))
        )
        let loaded = try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            let columns = try database.resolveTransactionRowColumns(db: db)
            return try cases.indices.map { index in
                (
                    batch: try database.transactionBatchSnapshot(id: "p\(index)", columns: columns, db: db),
                    undo: try database.transactionUndoSnapshot(id: "p\(index)", db: db)
                )
            }
        }
        for (index, item) in cases.enumerated() {
            let expected = item.expected
            let batch = try #require(loaded[index].batch, "\(item.label)")
            #expect(batch.amount == expected.int, "batch amount \(item.label)")
            #expect(batch.cleared == expected.flag, "batch cleared \(item.label)")
            #expect(batch.reconciled == expected.flag, "batch reconciled \(item.label)")
            #expect(batch.tombstone == expected.flag, "batch tombstone \(item.label)")
            #expect(batch.isParent == expected.flag, "batch isParent \(item.label)")
            #expect(batch.sortOrder == expected.sort, "batch sort \(item.label)")
            let undo = try #require(loaded[index].undo, "\(item.label)")
            #expect(undo.amount == expected.int ?? 0, "undo amount \(item.label)")
            #expect(undo.cleared == ((expected.int ?? 0) != 0), "undo cleared \(item.label)")
            #expect(undo.tombstone == ((expected.int ?? 0) != 0), "undo tombstone \(item.label)")
            #expect(undo.isParent == ((expected.int ?? 0) != 0), "undo isParent \(item.label)")
        }
    }

    // MARK: Legacy column spellings, empty strings, NULL isChild

    /// `account`, `payee`, `transfer_id`, `imported_id`, `is_child`; no parent flag column.
    private func aliasTwoDatabase() throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            DROP TABLE transactions;
            CREATE TABLE transactions (
                id TEXT PRIMARY KEY, account, date, amount, category, tombstone, parent_id,
                is_child, payee, transfer_id, imported_id, notes, cleared
            );
            INSERT INTO transactions VALUES
                ('child-null', 'checking', 20260703, -1250, '', NULL, 'p1', NULL, '', '', 'imp-1', '', 1);
            INSERT INTO transactions VALUES
                ('child-zero', 'checking', 20260703, -500, 'groceries', 0, 'p1', 0, 'pay', 'xfer', 'imp-2', 'memo', 0);
            """))
    }

    @Test func emptyStringsAndNullIsChildPerLoader() async throws {
        let database = try aliasTwoDatabase()
        let loaded = try await loadAll(database, ids: ["child-null", "child-zero"])
        let columns = try #require(loaded["child-null"]).columns

        // Empty strings. A text-typed integer is not pinned: every loader
        // decodes numbers with `row[column] as Int?`, which traps on text.
        let null = try #require(loaded["child-null"])
        #expect(null.split == SplitTransactionRecord(
            id: "child-null",
            amount: -1250,
            account: "checking",
            date: "2026-07-03",
            category: nil, // empty -> nil
            payee: nil,
            notes: nil,
            cleared: true,
            reconciled: false,
            startingBalance: nil,
            sortOrder: nil,
            isParent: false, // no parent flag column
            isChild: true, // NULL isChild with parent_id set
            parentID: "p1",
            transferID: nil,
            error: nil,
            deleted: false
        ))
        // D10: batch keeps empty strings and hard-codes the imported columns,
        // so `imported_id` is not read.
        #expect(null.batch == TransactionBatchTransactionSnapshot(
            id: "child-null",
            columns: columns,
            accountID: "checking",
            dateValue: 20_260_703,
            amount: -1250,
            payeeID: "",
            categoryID: "",
            notes: "",
            cleared: true,
            reconciled: nil,
            tombstone: nil,
            isParent: nil,
            isChild: true,
            parentID: "p1",
            transferID: "",
            sortOrder: nil,
            splitError: nil,
            startingBalance: nil,
            scheduleID: nil,
            importedID: nil,
            importedPayee: nil,
            importedDescription: nil
        ))
        // D1: undo ignores NULL isChild + parent_id, so it is not a child.
        #expect(null.undo == TransactionUndoSnapshot(
            id: "child-null",
            accountID: "checking",
            dateValue: 20_260_703,
            amount: -1250,
            payeeID: nil,
            categoryID: nil,
            notes: nil,
            cleared: true,
            tombstone: false,
            transferID: nil,
            isParent: false,
            isChild: false,
            parentID: "p1"
        ))

        // An explicit isChild = 0 with parent_id: split drops the parent, batch
        // and undo keep it.
        let zero = try #require(loaded["child-zero"])
        #expect(zero.split?.isChild == false)
        #expect(zero.split?.parentID == nil)
        #expect(zero.split?.transferID == "xfer")
        #expect(zero.batch?.isChild == false)
        #expect(zero.batch?.parentID == "p1")
        #expect(zero.undo?.isChild == false)
        #expect(zero.undo?.parentID == "p1")
        #expect(zero.undo?.transferID == "xfer")
    }

    /// `acct`, `description`, `transferred_id`, `financial_id`, `isParent`, `isChild`.
    @Test func firstSpellingColumnsAndImportedColumnsPerLoader() async throws {
        let database = try BudgetDatabase(databaseURL: support.makeSQLiteFixture(extraSQL: """
            DROP TABLE transactions;
            CREATE TABLE transactions (
                id TEXT PRIMARY KEY, acct, date, amount, category, tombstone, parent_id,
                isParent, isChild, description, transferred_id, financial_id,
                imported_payee, imported_description, notes, cleared
            );
            INSERT INTO transactions VALUES
                ('full', 'checking', 20260703, -1250, 'groceries', 0, 'p1',
                 0, 1, 'pay-1', 'xfer-1', 'fin-1', 'imp-payee', 'imp-desc', 'memo', 1);
            """))
        let loaded = try await loadAll(database, ids: ["full"])
        let row = try #require(loaded["full"])

        #expect(row.split == SplitTransactionRecord(
            id: "full",
            amount: -1250,
            account: "checking",
            date: "2026-07-03",
            category: "groceries",
            payee: "pay-1",
            notes: "memo",
            cleared: true,
            reconciled: false,
            startingBalance: nil,
            sortOrder: nil,
            isParent: false,
            isChild: true,
            parentID: "p1",
            transferID: "xfer-1",
            error: nil,
            deleted: false
        ))
        #expect(row.batch == TransactionBatchTransactionSnapshot(
            id: "full",
            columns: row.columns,
            accountID: "checking",
            dateValue: 20_260_703,
            amount: -1250,
            payeeID: "pay-1",
            categoryID: "groceries",
            notes: "memo",
            cleared: true,
            reconciled: nil,
            tombstone: false,
            isParent: false,
            isChild: true,
            parentID: "p1",
            transferID: "xfer-1",
            sortOrder: nil,
            splitError: nil,
            startingBalance: nil,
            scheduleID: nil,
            importedID: "fin-1",
            importedPayee: "imp-payee",
            importedDescription: "imp-desc"
        ))
        #expect(row.undo == TransactionUndoSnapshot(
            id: "full",
            accountID: "checking",
            dateValue: 20_260_703,
            amount: -1250,
            payeeID: "pay-1",
            categoryID: "groceries",
            notes: "memo",
            cleared: true,
            tombstone: false,
            transferID: "xfer-1",
            isParent: false,
            isChild: true,
            parentID: "p1"
        ))
    }

    @Test func missingRowReadsAsNilInEveryLoader() async throws {
        let database = try aliasTwoDatabase()
        let loaded = try await loadAll(database, ids: ["absent"])
        let row = try #require(loaded["absent"])
        #expect(row.split == nil)
        #expect(row.batch == nil)
        #expect(row.undo == nil)
    }
}
