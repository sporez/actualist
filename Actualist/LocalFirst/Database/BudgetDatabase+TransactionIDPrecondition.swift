import Foundation
import GRDB

extension BudgetDatabase {
    /// A caller-chosen primary transaction id a create is about to insert.
    /// The commit transaction checks it live, because an earlier attempt of the
    /// same editor presentation may already have committed. A tombstoned row
    /// counts as present: a create retried after a delete must not resurrect it.
    struct TransactionIDAbsence: Sendable {
        let transactionID: String

        func isViolated(in database: isolated BudgetDatabase, db: Database) throws -> Bool {
            try database.rowExists(table: "transactions", rowID: transactionID, db: db)
        }
    }
}
