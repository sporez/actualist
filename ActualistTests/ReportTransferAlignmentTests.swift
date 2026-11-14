import Foundation
import GRDB
import Testing
@testable import Actualist

struct ReportTransferAlignmentTests {
    private func leg(
        _ id: String, _ transfer: String, _ account: String, _ amount: Int, _ day: String
    ) -> ReportTransferLeg {
        ReportTransferLeg(id: id, transferID: transfer, accountID: account, amount: amount, dayID: day)
    }

    private func read<T: Sendable>(
        _ database: isolated BudgetDatabase,
        _ body: @Sendable (isolated BudgetDatabase, Database) throws -> T
    ) throws -> T {
        try database.queue.read { db in try body(database, db) }
    }

    private func amounts(_ days: [RawNetWorthDay]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.dayID, $0.amount) })
    }

    @Test func movesTheEarlierLegOntoTheLaterDay() throws {
        // Out of checking on the 1st (-500), into savings on the 3rd (+500): both land on the 3rd.
        let days = [
            RawNetWorthDay(dayID: "2026-07-01", amount: -500),
            RawNetWorthDay(dayID: "2026-07-03", amount: 500),
        ]
        let legs = [
            leg("out", "in", "checking", -500, "2026-07-01"),
            leg("in", "out", "savings", 500, "2026-07-03"),
        ]
        let aligned = try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")
        #expect(amounts(aligned) == ["2026-07-01": 0, "2026-07-03": 0])
    }

    @Test func movesTheInflowWhenItIsTheEarlierLeg() throws {
        let days = [
            RawNetWorthDay(dayID: "2026-07-01", amount: 500),
            RawNetWorthDay(dayID: "2026-07-03", amount: -500),
        ]
        let legs = [
            leg("in", "out", "savings", 500, "2026-07-01"),
            leg("out", "in", "checking", -500, "2026-07-03"),
        ]
        let aligned = try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")
        #expect(amounts(aligned) == ["2026-07-01": 0, "2026-07-03": 0])
    }

    @Test func createsTheLaterDayWhenNoOtherRowFallsOnIt() throws {
        // Both legs of an off-budget pair are in the read, but the report only sums their days.
        let days = [RawNetWorthDay(dayID: "2026-07-01", amount: -500)]
        let legs = [
            leg("out", "in", "checking", -500, "2026-07-01"),
            leg("in", "out", "savings", 500, "2026-07-03"),
        ]
        let aligned = try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")
        #expect(amounts(aligned) == ["2026-07-01": 0, "2026-07-03": -500])
    }

    @Test func aLaterLegAfterTheEndOnlyRemovesTheEarlierAmount() throws {
        let days = [RawNetWorthDay(dayID: "2026-07-30", amount: -500)]
        let legs = [
            leg("out", "in", "checking", -500, "2026-07-30"),
            leg("in", "out", "savings", 500, "2026-08-02"),
        ]
        let aligned = try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")
        #expect(amounts(aligned) == ["2026-07-30": 0])
    }

    @Test func skipsPairsThatDoNotQualify() throws {
        let days = [
            RawNetWorthDay(dayID: "2026-07-01", amount: -500),
            RawNetWorthDay(dayID: "2026-07-03", amount: 400),
        ]
        let original = amounts(days)
        // Amounts that do not cancel.
        var legs = [
            leg("out", "in", "checking", -500, "2026-07-01"),
            leg("in", "out", "savings", 400, "2026-07-03"),
        ]
        #expect(amounts(try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")) == original)
        // The link points one way only.
        legs = [
            leg("out", "in", "checking", -500, "2026-07-01"),
            leg("in", "elsewhere", "savings", 500, "2026-07-03"),
        ]
        #expect(amounts(try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")) == original)
        // The counterpart is not among the counted legs.
        legs = [leg("out", "in", "checking", -500, "2026-07-01")]
        #expect(amounts(try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")) == original)
        // Both legs sit in one account.
        legs = [
            leg("out", "in", "checking", -500, "2026-07-01"),
            leg("in", "out", "checking", 500, "2026-07-03"),
        ]
        #expect(amounts(try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")) == original)
        // Same-day pairs are already aligned.
        legs = [
            leg("out", "in", "checking", -500, "2026-07-03"),
            leg("in", "out", "savings", 500, "2026-07-03"),
        ]
        #expect(amounts(try ReportTransferAlignment.align(days, legs: legs, through: "2026-07-31")) == original)
    }

    @Test func readsOnlyLiveLegsOfCountedAccountsFromOneQuery() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ActualistTransferLegs-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT, offbudget INTEGER, closed INTEGER, tombstone INTEGER);
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, acct TEXT, date INTEGER, amount INTEGER, category TEXT,
                    description TEXT, tombstone INTEGER, parent_id TEXT, isParent INTEGER, transferred_id TEXT
                );
                INSERT INTO accounts VALUES ('checking', 'Checking', 0, 0, 0);
                INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0);
                INSERT INTO accounts VALUES ('gone', 'Gone', 0, 0, 1);
                INSERT INTO transactions VALUES ('out', 'checking', 20260701, -500, NULL, NULL, 0, NULL, 0, 'in');
                INSERT INTO transactions VALUES ('in', 'savings', 20260703, 500, NULL, NULL, 0, NULL, 0, 'out');
                INSERT INTO transactions VALUES ('dead', 'checking', 20260704, -1, NULL, NULL, 1, NULL, 0, 'x');
                INSERT INTO transactions VALUES ('orphan', 'gone', 20260705, -2, NULL, NULL, 0, NULL, 0, 'y');
                INSERT INTO transactions VALUES ('plain', 'checking', 20260706, -3, NULL, NULL, 0, NULL, 0, NULL);
                """)
        }
        let database = try BudgetDatabase(databaseURL: url)
        let all = try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            try database.reportTransferLegs(accountIDs: nil, db: db)
        }
        #expect(all.map(\.id).sorted() == ["in", "out"])
        let checking = try await read(database) { (database: isolated BudgetDatabase, db: Database) in
            try database.reportTransferLegs(accountIDs: ["checking"], db: db)
        }
        #expect(checking.map(\.id) == ["out"])
        #expect(checking.first == ReportTransferLeg(
            id: "out", transferID: "in", accountID: "checking", amount: -500, dayID: "2026-07-01"
        ))
    }
}
