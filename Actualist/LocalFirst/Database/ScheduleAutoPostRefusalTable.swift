import Foundation
import GRDB

/// Device-local record of automatic schedule posts that were refused. The
/// `actualist_` table is never part of CRDT sync, so it stays with this budget's
/// database file: another budget has its own file, and erasing local data
/// deletes it. Stateless; callers pass the handle inside their own transaction.
enum ScheduleAutoPostRefusalTable {
    private static let table = "actualist_schedule_auto_post_refusals"

    static func read(_ db: Database) throws -> [ScheduleAutoPostRefusal] {
        guard try Row.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil else {
            return []
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY schedule_id").compactMap { row in
            // An unknown reason (a newer build wrote it) is dropped, not guessed.
            guard let scheduleID = row["schedule_id"] as String?,
                  let day = row["occurrence_day_id"] as String?,
                  let refusal = (row["refusal"] as String?).flatMap(SchedulePostingRefusal.init(rawValue:)) else {
                return nil
            }
            return ScheduleAutoPostRefusal(
                scheduleID: scheduleID,
                scheduleName: row["schedule_name"] as String?,
                occurrenceDayID: day,
                refusal: refusal
            )
        }
    }

    /// Replaces the whole set. A finished posting run's result supersedes the last one.
    static func replace(with refusals: [ScheduleAutoPostRefusal], _ db: Database) throws {
        try createIfNeeded(db)
        try db.execute(sql: "DELETE FROM \(table)")
        for refusal in refusals {
            try insert(refusal, db)
        }
    }

    /// Removes only the exact entries given, so a prune based on an older read
    /// cannot delete a refusal a newer run just recorded for the same schedule.
    static func remove(_ refusals: [ScheduleAutoPostRefusal], _ db: Database) throws {
        guard try Row.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) != nil else {
            return
        }
        for refusal in refusals {
            try db.execute(
                sql: "DELETE FROM \(table) WHERE schedule_id = ? AND occurrence_day_id = ?",
                arguments: [refusal.scheduleID, refusal.occurrenceDayID]
            )
        }
    }

    private static func createIfNeeded(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS \(table) (
                schedule_id TEXT PRIMARY KEY,
                schedule_name TEXT,
                occurrence_day_id TEXT NOT NULL,
                refusal TEXT NOT NULL
            )
            """)
    }

    private static func insert(_ refusal: ScheduleAutoPostRefusal, _ db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO \(table) (schedule_id, schedule_name, occurrence_day_id, refusal)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [refusal.scheduleID, refusal.scheduleName, refusal.occurrenceDayID, refusal.refusal.rawValue]
        )
    }
}
