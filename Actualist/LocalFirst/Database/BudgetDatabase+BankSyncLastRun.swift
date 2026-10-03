import Foundation
import GRDB

/// Device-local record of the last finished Bank Sync run. The `actualist_`
/// table is never part of CRDT sync, so the record stays on this device and
/// with this budget.
extension BudgetDatabase {
    func bankSyncLastRun() throws -> BankSyncLastRun? {
        try queue.read { db in
            guard try tableExists("actualist_bank_sync_last_run", db: db),
                  let row = try Row.fetchOne(
                    db,
                    sql: "SELECT finished_at, trigger, summary FROM actualist_bank_sync_last_run WHERE id = 1"
                  ),
                  let finishedAt = row["finished_at"] as Double?,
                  let trigger = (row["trigger"] as String?).flatMap(BankSyncLastRun.Trigger.init(rawValue:)),
                  let summary = row["summary"] as String? else {
                return nil
            }
            return BankSyncLastRun(
                finishedAt: Date(timeIntervalSince1970: finishedAt),
                trigger: trigger,
                summary: summary
            )
        }
    }

    func saveBankSyncLastRun(_ run: BankSyncLastRun) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS actualist_bank_sync_last_run (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    finished_at REAL NOT NULL,
                    trigger TEXT NOT NULL,
                    summary TEXT NOT NULL
                )
                """)
            // Invalidate the cached miss. Caching true here would survive a transaction rollback.
            tableExistsCache["actualist_bank_sync_last_run"] = nil
            try db.execute(
                sql: """
                    INSERT INTO actualist_bank_sync_last_run (id, finished_at, trigger, summary)
                    VALUES (1, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        finished_at = excluded.finished_at,
                        trigger = excluded.trigger,
                        summary = excluded.summary
                    """,
                arguments: [run.finishedAt.timeIntervalSince1970, run.trigger.rawValue, run.summary]
            )
        }
    }
}
