import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actualist

/// Phase 5.5: a month fetch reads only the notes it can look up (that month,
/// category groups and categories), not every account, payee and month note.
@MainActor
struct BudgetMonthNoteScopeTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func monthFetchFlagsMatchAFullNoteReadWhileReadingOnlyScopedRows() async throws {
        let noise = (0..<300).map { "INSERT INTO notes VALUES ('account-a\($0)', 'Account note \($0)');" }
            + (0..<24).map { "INSERT INTO notes VALUES ('budget-2025-\(String(format: "%02d", $0 % 12 + 1))x\($0)', 'Month');" }
        let url = try fixtures.makeSQLiteFixture(extraSQL: """
            CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);
            INSERT INTO notes VALUES ('budget-2026-07', 'July note');
            INSERT INTO notes VALUES ('budget-2026-06', 'June note');
            INSERT INTO notes VALUES ('group', 'Group note');
            INSERT INTO notes VALUES ('utilities', 'Utilities note');
            INSERT INTO notes VALUES ('groceries', '');
            INSERT INTO notes VALUES ('orphan', 'No such category');
            \(noise.joined(separator: "\n"))
            """)
        let database = try BudgetDatabase(databaseURL: url)
        let statements = Mutex<[String]>([])
        let queue = await database.queue
        try await queue.read { db in
            db.trace { event in
                if case .statement(let statement) = event, statement.sql.contains("FROM notes") {
                    statements.withLock { $0.append(statement.expandedSQL) }
                }
            }
        }

        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let reads = statements.withLock { $0 }

        // The flags equal what a lookup against the whole notes table gives.
        let full = try await queue.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT id, note FROM notes").compactMap { row -> String? in
                ActualNoteBody(storedNote: row["note"]).hasUserNote ? row["id"] : nil
            })
        }
        let categories = month.categoryGroups.flatMap(\.categories)
        for group in month.categoryGroups { #expect(group.hasUserNote == full.contains(group.id)) }
        for category in categories { #expect(category.hasUserNote == full.contains(category.id)) }
        #expect(month.hasUserNote == full.contains("budget-2026-07"))
        #expect(categories.first { $0.id == "groceries" }?.hasUserNote == false)
        #expect(month.categoryGroups.first { $0.id == "group" }?.hasUserNote == true)
        #expect(month.hasUserNote)

        // Work count: one notes read, returning only the scoped rows.
        #expect(reads.count == 1)
        let rowsRead = try await queue.read { db in
            try Row.fetchAll(db, sql: reads.first ?? "SELECT 1 WHERE 0").count
        }
        // The month note, the group note and the empty-note category.
        #expect(rowsRead == 3)
        #expect(full.count > 300)
    }
}
