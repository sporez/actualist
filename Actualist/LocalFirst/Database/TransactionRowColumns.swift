import Foundation
import GRDB

extension BudgetDatabase {
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

/// Lets readers outside `BudgetDatabase` name the columns without the prefix.
typealias TransactionRowColumns = BudgetDatabase.TransactionRowColumns
