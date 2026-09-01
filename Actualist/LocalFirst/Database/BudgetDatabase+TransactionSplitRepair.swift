import Foundation
import GRDB

extension BudgetDatabase {
    func repairSplitTransactionsMessages(
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (result: SplitTransactionRepairResult, write: TransactionWriteResult) {
        try queue.read { db in
            let columns = try resolveTransactionRowColumns(db: db)
            var repair = SplitTransactionRepairResult()
            var oldByID: [String: SplitTransactionRecord] = [:]
            var newByID: [String: SplitTransactionRecord] = [:]

            func record(_ id: String) throws -> SplitTransactionRecord {
                if let cached = newByID[id] ?? oldByID[id] {
                    return cached
                }
                guard let loaded = try loadTransactionRecord(id: id, columns: columns, db: db) else {
                    throw LocalFirstError.invalidLocalWrite("missing transaction")
                }
                oldByID[id] = loaded
                newByID[id] = loaded
                return loaded
            }

            func update(_ id: String, _ mutate: (inout SplitTransactionRecord) -> Void) throws {
                var next = try record(id)
                if oldByID[id] == nil {
                    oldByID[id] = next
                }
                mutate(&next)
                newByID[id] = next
            }

            let liveChild = predicateForLiveRows(columns: columns.all, tableAlias: "child")
            let payeeColumn = columns.payee
            if let isChildColumn = columns.isChild, columns.hasParentID {
                let blankRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT child.id AS id, parent.\(payeeColumn) AS parentPayee
                        FROM transactions child
                        JOIN transactions parent ON child.parent_id = parent.id
                        WHERE child.\(isChildColumn) = 1
                          AND (child.\(payeeColumn) IS NULL OR child.\(payeeColumn) = '')
                          AND parent.\(payeeColumn) IS NOT NULL
                          AND parent.\(payeeColumn) != ''
                          AND \(liveChild)
                        """
                )
                repair.blankPayeeCount = blankRows.count
                for row in blankRows {
                    let id: String = row["id"]
                    let parentPayee: String = row["parentPayee"]
                    try update(id) { $0.payee = parentPayee }
                }

                if columns.hasCleared {
                    let clearedRows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT child.id AS id, parent.cleared AS cleared
                            FROM transactions child
                            JOIN transactions parent ON child.parent_id = parent.id
                            WHERE child.\(isChildColumn) = 1
                              AND IFNULL(child.cleared, 0) != IFNULL(parent.cleared, 0)
                              AND \(liveChild)
                            """
                    )
                    repair.clearedCount = clearedRows.count
                    for row in clearedRows {
                        let id: String = row["id"]
                        try update(id) { $0.cleared = flexibleBool(row["cleared"]) }
                    }
                }

                let orphanSQL = columns.hasTombstone
                    ? """
                        SELECT child.id AS id
                        FROM transactions child
                        LEFT JOIN transactions parent ON child.parent_id = parent.id
                        WHERE child.\(isChildColumn) = 1
                          AND child.tombstone = 0
                          AND (parent.id IS NULL OR parent.tombstone = 1)
                        """
                    : """
                        SELECT child.id AS id
                        FROM transactions child
                        LEFT JOIN transactions parent ON child.parent_id = parent.id
                        WHERE child.\(isChildColumn) = 1
                          AND parent.id IS NULL
                        """
                let orphanIDs = try String.fetchAll(db, sql: orphanSQL)
                repair.deletedCount = orphanIDs.count
                for id in orphanIDs {
                    try update(id) { $0.deleted = true }
                }
            }

            if let transferColumn = columns.transferID, try tableExists("accounts", db: db) {
                let broken = try String.fetchAll(
                    db,
                    sql: """
                        SELECT t1.id
                        FROM transactions t1
                        JOIN accounts a1 ON t1.\(columns.account) = a1.id
                        JOIN transactions t2 ON t1.\(transferColumn) = t2.id
                        JOIN accounts a2 ON t2.\(columns.account) = a2.id
                        WHERE IFNULL(a1.offbudget, 0) = IFNULL(a2.offbudget, 0)
                          AND t1.category IS NOT NULL
                        """
                )
                repair.transfersFixedCount = broken.count
                for id in broken {
                    try update(id) { $0.category = nil }
                }
            }

            if columns.hasError, let isParentColumn = columns.isParent {
                let errorIDs = try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM transactions
                        WHERE error IS NOT NULL AND IFNULL(\(isParentColumn), 0) = 0
                        """
                )
                repair.nonParentErrorsFixedCount = errorIDs.count
                for id in errorIDs {
                    try update(id) { $0.error = nil }
                }

                let parentCategoryIDs = try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM transactions
                        WHERE IFNULL(\(isParentColumn), 0) = 1 AND category IS NOT NULL
                        """
                )
                repair.parentCategoriesFixedCount = parentCategoryIDs.count
                for id in parentCategoryIDs {
                    try update(id) { $0.category = nil }
                }
            }

            let families = try loadLiveParentFamilies(columns: columns, db: db)
            repair.mismatchedParentIDs = families.compactMap { family in
                SplitTransactionFamilyOps.recalculateSplit(family).error == nil ? nil : family.id
            }

            let oldRows = Array(oldByID.values)
            let surviving = oldByID.keys.compactMap { newByID[$0] }.filter { !$0.deleted }
            let write = try persistFamilyChange(
                oldRows: oldRows,
                newRows: surviving,
                columns: columns,
                db: db,
                builder: &builder
            )
            return (repair, write)
        }
    }
}
