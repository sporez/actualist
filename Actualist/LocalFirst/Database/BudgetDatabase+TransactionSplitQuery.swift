import Foundation
import GRDB

enum TransactionSplitQueryMode: String, Equatable, Sendable {
    case all
    case inline
    case none
    case grouped
}

/// Actual 26.8.1 AQL-equivalent split expressions over the physical
/// `transactions` table. Callers compose these; they do not execute queries.
struct TransactionSplitQueryExpressions: Equatable, Sendable {
    let tableAlias: String
    let account: String
    let date: String
    let amount: String
    let category: String
    let payee: String
    let notes: String
    let parentID: String
    let isParent: String
    let isChild: String
    let sortOrder: String
    let startingBalance: String
    let error: String
    let cleared: String
    let reconciled: String
    let importedPayee: String
    let schedule: String
    let tombstone: String?
    let hasIsChildColumn: Bool
    let hasParentIDColumn: Bool
    let hasSortOrderColumn: Bool
    let hasStartingBalanceColumn: Bool

    var qualifiedAccount: String { qualify(account) }
    var qualifiedDate: String { qualify(date) }
    var qualifiedAmount: String { qualify(amount) }
    var qualifiedCategory: String { qualify(category) }
    var qualifiedPayee: String { qualify(payee) }
    var qualifiedNotes: String { qualify(notes) }
    var qualifiedParentID: String { qualify(parentID) }
    var qualifiedIsParent: String { qualify(isParent) }
    var qualifiedIsChild: String { qualify(isChild) }
    var qualifiedSortOrder: String { qualify(sortOrder) }
    var qualifiedStartingBalance: String { qualify(startingBalance) }
    var qualifiedError: String { qualify(error) }
    var qualifiedCleared: String { qualify(cleared) }
    var qualifiedReconciled: String { qualify(reconciled) }
    var qualifiedImportedPayee: String { qualify(importedPayee) }
    var qualifiedSchedule: String { qualify(schedule) }

    /// `v_transactions_internal` parent_id: flags are authoritative.
    var effectiveParentID: String {
        "CASE WHEN (\(qualifiedIsChild)) = 0 THEN NULL ELSE \(qualifiedParentID) END"
    }

    /// Parent category is null in the effective view.
    func effectiveCategory(mappedCategory: String) -> String {
        "CASE WHEN (\(qualifiedIsParent)) = 1 THEN NULL ELSE \(mappedCategory) END"
    }

    /// `v_transactions_internal` row filter.
    var internalViewPredicate: String {
        "\(qualifiedDate) IS NOT NULL AND \(qualifiedAccount) IS NOT NULL AND ((\(qualifiedIsChild)) = 0 OR \(qualifiedParentID) IS NOT NULL)"
    }

    var liveRowPredicate: String {
        guard let tombstone else { return "1 = 1" }
        return "(\(qualify(tombstone)) IS NULL OR \(qualify(tombstone)) = 0)"
    }

    func parentJoin(parentAlias: String = "parent") -> String {
        "LEFT JOIN transactions \(parentAlias) ON ((\(qualifiedIsChild)) = 1 AND \(parentAlias).id = \(qualifiedParentID))"
    }

    /// `v_transactions_internal_alive` child/parent liveness.
    func alivePredicate(parentAlias: String = "parent") -> String {
        guard let tombstone else {
            return "((\(qualifiedIsChild)) = 0 OR 1 = 1)"
        }
        // Actual uses `t2.tombstone = 0`; a missing parent yields NULL and is not live.
        return "((\(qualifiedIsChild)) = 0 OR \(parentAlias).\(tombstone) = 0)"
    }

    func liveEffectivePredicate(parentAlias: String = "parent") -> String {
        [
            liveRowPredicate,
            internalViewPredicate,
            alivePredicate(parentAlias: parentAlias),
        ].joined(separator: " AND ")
    }

    /// Alive non-parent rows: account balances, budget spending, reports.
    func liveInlinePredicate(parentAlias: String = "parent") -> String {
        [
            liveEffectivePredicate(parentAlias: parentAlias),
            splitModePredicate(.inline),
        ].joined(separator: " AND ")
    }

    func splitModePredicate(_ mode: TransactionSplitQueryMode) -> String {
        switch mode {
        case .all, .grouped:
            return "1 = 1"
        case .inline:
            return "(\(qualifiedIsParent) = 0 OR \(qualifiedIsParent) IS NULL)"
        case .none:
            return "\(effectiveParentID) IS NULL"
        }
    }

    func defaultOrder(normalizedDate: String) -> String {
        var terms = ["\(normalizedDate) DESC"]
        if hasStartingBalanceColumn {
            terms.append("\(qualifiedStartingBalance) ASC")
        }
        if hasSortOrderColumn {
            terms.append("\(qualifiedSortOrder) DESC")
        }
        terms.append("\(tableAlias).id ASC")
        return terms.joined(separator: ", ")
    }

    private func qualify(_ expression: String) -> String {
        if expression == "NULL" || expression == "0" || expression.contains(".") || expression.contains("(") {
            return expression
        }
        return "\(tableAlias).\(expression)"
    }
}

extension BudgetDatabase {
    func transactionSplitQueryExpressions(
        columns: Set<String>,
        tableAlias: String = "t"
    ) -> TransactionSplitQueryExpressions {
        func physical(_ names: [String], fallback: String) -> String {
            names.first(where: columns.contains) ?? fallback
        }
        let hasIsChildColumn = columns.contains("isChild") || columns.contains("is_child")
        let hasParentIDColumn = columns.contains("parent_id")
        let isChild: String
        if hasIsChildColumn {
            let name = physical(["isChild", "is_child"], fallback: "0")
            if hasParentIDColumn {
                // NULL isChild is unmigrated, not an explicit 0. Explicit 0 still wins over parent_id.
                isChild = """
                    CASE
                        WHEN \(tableAlias).\(name) IS NULL THEN CASE WHEN \(tableAlias).parent_id IS NULL OR \(tableAlias).parent_id = '' THEN 0 ELSE 1 END
                        WHEN \(tableAlias).\(name) = 0 THEN 0
                        ELSE 1
                    END
                    """
            } else {
                isChild = "IFNULL(\(tableAlias).\(name), 0)"
            }
        } else if hasParentIDColumn {
            // Permissive fixtures omit isChild; parent_id then stands in.
            isChild = "CASE WHEN \(tableAlias).parent_id IS NULL OR \(tableAlias).parent_id = '' THEN 0 ELSE 1 END"
        } else {
            isChild = "0"
        }
        let isParent: String
        if let name = ["isParent", "is_parent"].first(where: columns.contains) {
            isParent = "IFNULL(\(tableAlias).\(name), 0)"
        } else {
            isParent = "0"
        }
        return TransactionSplitQueryExpressions(
            tableAlias: tableAlias,
            account: physical(["acct", "account"], fallback: "NULL"),
            date: physical(["date"], fallback: "NULL"),
            amount: physical(["amount"], fallback: "0"),
            category: physical(["category"], fallback: "NULL"),
            payee: physical(["description", "payee"], fallback: "NULL"),
            notes: physical(["notes"], fallback: "NULL"),
            parentID: physical(["parent_id"], fallback: "NULL"),
            isParent: isParent,
            isChild: isChild,
            sortOrder: physical(["sort_order"], fallback: "0"),
            startingBalance: physical(["starting_balance_flag"], fallback: "0"),
            error: physical(["error"], fallback: "NULL"),
            cleared: physical(["cleared"], fallback: "0"),
            reconciled: physical(["reconciled"], fallback: "0"),
            importedPayee: physical(["imported_description", "imported_payee"], fallback: "NULL"),
            schedule: physical(["schedule"], fallback: "NULL"),
            tombstone: columns.contains("tombstone") ? "tombstone" : (columns.contains("deleted") ? "deleted" : nil),
            hasIsChildColumn: hasIsChildColumn,
            hasParentIDColumn: hasParentIDColumn,
            hasSortOrderColumn: columns.contains("sort_order"),
            hasStartingBalanceColumn: columns.contains("starting_balance_flag")
        )
    }

    func parseSplitTransactionError(_ value: DatabaseValueConvertible?) -> SplitTransactionError? {
        let raw: String?
        if let value = value as? String {
            raw = value
        } else {
            raw = flexibleString(value)
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null", let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(SplitTransactionError.self, from: data)
    }
}
