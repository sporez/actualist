import Foundation
import GRDB

/// The physical `transactions` columns. They vary across schema versions
/// and test fixtures, so every reader and writer resolves them here.
struct TransactionRowColumns {
    let all: Set<String>
    let account: String
    let payee: String
    let isParent: String?
    let isChild: String?
    let transferID: String?
    let sortOrder: String?

    var hasNotes: Bool { all.contains("notes") }
    var hasCleared: Bool { all.contains("cleared") }
    var hasReconciled: Bool { all.contains("reconciled") }
    var hasTombstone: Bool { all.contains("tombstone") }
    var hasParentID: Bool { all.contains("parent_id") }
    var hasSchedule: Bool { all.contains("schedule") }
    var hasError: Bool { all.contains("error") }
    var hasStartingBalance: Bool { all.contains("starting_balance_flag") }

    var importedID: String? { Self.importedID(in: all) }
    var importedPayee: String? { Self.importedPayee(in: all) }

    // Each alias list is in preference order. A reader that needs a column
    // to exist passes the list to `firstExistingColumn`, which names it in
    // its error.
    static let accountAliases = ["acct", "account"]
    /// The payee reference. Older schemas call it `description`.
    static let payeeAliases = ["description", "payee"]
    static let importedIDAliases = ["financial_id", "imported_id"]
    static let importedPayeeAliases = ["imported_description", "imported_payee"]
    static let transferIDAliases = ["transferred_id", "transfer_id"]
    static let isParentAliases = ["isParent", "is_parent"]
    static let isChildAliases = ["isChild", "is_child"]

    static func account(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: accountAliases, in: columns)
    }

    static func payee(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: payeeAliases, in: columns)
    }

    static func importedID(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: importedIDAliases, in: columns)
    }

    static func importedPayee(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: importedPayeeAliases, in: columns)
    }

    static func transferID(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: transferIDAliases, in: columns)
    }

    static func isParent(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: isParentAliases, in: columns)
    }

    static func isChild(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: isChildAliases, in: columns)
    }

    /// The `transactions` columns of this budget. Throws when a column every
    /// reader needs is missing.
    static func resolve(in database: isolated BudgetDatabase, db: Database) throws -> TransactionRowColumns {
        let columns = try database.requiredColumns(
            table: "transactions",
            required: ["date", "amount", "category"],
            db: db
        )
        return TransactionRowColumns(
            all: columns,
            account: try database.firstExistingColumn(accountAliases, in: columns, table: "transactions"),
            payee: try database.firstExistingColumn(payeeAliases, in: columns, table: "transactions"),
            isParent: Self.isParent(in: columns),
            isChild: Self.isChild(in: columns),
            transferID: Self.transferID(in: columns),
            sortOrder: columns.contains("sort_order") ? "sort_order" : nil
        )
    }

    /// The messages that write one `transactions` row; `cells` picks which.
    func rowMessages(
        rowID: String,
        accountID: String,
        dateValue: Int,
        amountMinorUnits: Int,
        payeeID: String?,
        categoryID: String?,
        notes: String?,
        cleared: Bool,
        reconciled: Bool? = nil,
        isParent: Bool,
        parentID: String?,
        isChild: Bool,
        transferID: String?,
        sortOrder: Double?,
        error: SplitTransactionError? = nil,
        startingBalance: Bool? = nil,
        builder: inout LocalFirstSyncMessageBuilder,
        scheduleID: String? = nil,
        cells: TransactionRowCells = .inserted()
    ) throws -> [ActualSyncDecodedMessage] {
        let snapshot = cells.isSnapshot
        var fields: [(String, LocalFirstSyncValue)] = [
            (account, .string(accountID)),
            ("date", .int(Int64(dateValue))),
            ("amount", .int(Int64(amountMinorUnits)))
        ]
        if snapshot || payeeID != nil {
            fields.append((payee, payeeID.map(LocalFirstSyncValue.string) ?? .null))
        }
        if snapshot || categoryID != nil || cells.clearsCategory {
            fields.append(("category", categoryID.map(LocalFirstSyncValue.string) ?? .null))
        }
        if hasNotes, snapshot || notes != nil {
            fields.append(("notes", notes.map(LocalFirstSyncValue.string) ?? .null))
        }
        if hasCleared {
            fields.append(("cleared", .bool(cleared)))
        }
        if hasReconciled, let reconciled = snapshot ? reconciled : false {
            fields.append(("reconciled", .bool(reconciled)))
        }
        if snapshot, let isParentColumn = self.isParent {
            fields.append((isParentColumn, .bool(isParent)))
        }
        if snapshot, hasParentID {
            fields.append(("parent_id", parentID.map(LocalFirstSyncValue.string) ?? .null))
        }
        if snapshot, let isChildColumn = self.isChild {
            fields.append((isChildColumn, .bool(isChild)))
        }
        if let transferID, let transferColumn = self.transferID {
            fields.append((transferColumn, .string(transferID)))
        }
        if let sortOrder, let sortOrderColumn = self.sortOrder {
            fields.append((sortOrderColumn, .double(sortOrder)))
        }
        if snapshot, hasTombstone {
            fields.append(("tombstone", .bool(false)))
        }
        if let scheduleID, hasSchedule {
            fields.append(("schedule", .string(scheduleID)))
        }
        if snapshot, hasError {
            fields.append(("error", SplitTransactionError.syncValue(error)))
        }
        if let startingBalance, hasStartingBalance {
            fields.append(("starting_balance_flag", .bool(startingBalance)))
        }

        var messages: [ActualSyncDecodedMessage] = []
        for (column, value) in fields {
            messages.append(
                try builder.makeMessage(dataset: "transactions", row: rowID, column: column, value: value)
            )
        }
        return messages
    }
}

/// Which cells `TransactionRowColumns.rowMessages` writes for a row.
enum TransactionRowCells {
    /// Actual's insert: only the cells it sets, so an absent payee, category or notes and the
    /// structural defaults (tombstone, isParent, parent_id, isChild, error) stay unwritten.
    /// `clearsCategory` writes a null category, as Actual does on the source leg of a transfer
    /// between accounts on the same side of the budget.
    case inserted(clearsCategory: Bool = false)
    /// Every stored column, for a row rewritten from a snapshot or a split plan: an unset value
    /// must overwrite what the row held before, and a restored row must be live again.
    case snapshot

    var isSnapshot: Bool {
        if case .snapshot = self { return true }
        return false
    }

    var clearsCategory: Bool {
        if case .inserted(let clears) = self { return clears }
        return false
    }
}

/// The `categories` columns that vary across schema versions.
enum CategoryColumns {
    /// The group a category belongs to.
    static let groupAliases = ["cat_group", "group_id"]

    static func group(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: groupAliases, in: columns)
    }
}

/// The columns that tie a payee to an account.
enum AccountColumns {
    /// The account a transfer payee stands for.
    static let transferPayeeAliases = ["transfer_acct", "transferAccount"]

    static func transferPayee(in columns: Set<String>) -> String? {
        SQLiteSchema.first(of: transferPayeeAliases, in: columns)
    }
}
