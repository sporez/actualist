import Foundation
import GRDB
import Testing
@testable import Actualist

@Suite("Report Explorer")
struct ReportExplorerTests {
    @Test func presetsAndIntervalsUseInclusiveCalendarDayBoundaries() throws {
        let now = try #require(ReportCalendar.gregorianLocal.date(
            from: DateComponents(year: 2024, month: 2, day: 29, hour: 12)
        ))
        let range = try #require(ReportExplorerRangePreset.threeMonths.range(through: now))
        #expect(range.startDay == "2023-12-01")
        #expect(range.endDay == "2024-02-29")

        let monthly = ReportExplorerQuery(
            metric: .cashFlow,
            startDay: "2024-01-15",
            endDay: "2024-03-03",
            interval: .month
        )
        #expect(monthly.periods == [
            ReportExplorerPeriod(startDay: "2024-01-15", endDay: "2024-01-31"),
            ReportExplorerPeriod(startDay: "2024-02-01", endDay: "2024-02-29"),
            ReportExplorerPeriod(startDay: "2024-03-01", endDay: "2024-03-03"),
        ])

        let daily = ReportExplorerQuery(
            metric: .spending,
            startDay: "2024-02-28",
            endDay: "2024-03-01",
            interval: .day
        )
        #expect(daily.periods.map(\.startDay) == ["2024-02-28", "2024-02-29", "2024-03-01"])
    }

    @Test func allReportCardsHaveTruthfulDistinctDetailConfigurations() {
        let mappings = ReportCardKind.allCases.map {
            "\($0.rawValue)|\($0.explorerMetric.rawValue)|\($0.explorerDefaultPreset.rawValue)|\($0.explorerDefaultInterval.rawValue)"
        }

        #expect(mappings == [
            "netWorth|netWorth|sixMonths|month",
            "cashFlow|cashFlow|monthToDate|month",
            "monthComparison|spending|monthToDate|day",
            "budgetOverview|budgetOverview|monthToDate|day",
            "threeMonthAverage|spendingAverage|threeMonths|month",
            "transactionCalendar|cashFlow|monthToDate|day",
        ])
    }

    @Test func cashFlowSeparatesSameDayMixedSignsIncludingSplitChildrenAndRefunds() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let query = ReportExplorerQuery(
            metric: .cashFlow,
            startDay: "2026-01-20",
            endDay: "2026-01-20",
            interval: .day
        )

        let snapshot = try await database.fetchReportExplorer(query: query)

        #expect(snapshot.points.count == 1)
        #expect(snapshot.points[0].income == 52_500)
        #expect(snapshot.points[0].expenses == 13_000)
        #expect(snapshot.points[0].net == 39_500)
        #expect(snapshot.totals.income == 52_500)
        #expect(snapshot.totals.expenses == 13_000)
        #expect(snapshot.totals.net == 39_500)

        let transferOnly = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .cashFlow,
            startDay: "2026-01-21",
            endDay: "2026-01-23",
            interval: .day
        ))
        #expect(transferOnly.points.allSatisfy { $0.income == 0 && $0.expenses == 0 })
        #expect(!transferOnly.hasData)
    }

    @Test func spendingUsesSignedNonIncomeRowsAndKeepsOnBudgetTransferBalancing() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let query = ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-20",
            endDay: "2026-01-23",
            interval: .day
        )

        let snapshot = try await database.fetchReportExplorer(query: query)

        #expect(snapshot.points.map(\.expenses) == [11_000, 2_000, 0, -2_000])
        #expect(snapshot.totals.income == 0)
        #expect(snapshot.totals.expenses == 11_000)
        #expect(snapshot.totals.net == -11_000)
    }

    @Test func budgetOverviewAddsAProportionalBudgetSeries() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let query = ReportExplorerQuery(
            metric: .budgetOverview,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month
        )

        let snapshot = try await database.fetchReportExplorer(query: query)

        #expect(snapshot.points.map(\.expenses) == [11_000])
        #expect(snapshot.points.map(\.budgeted) == [31_000])
        #expect(snapshot.totals.budgeted == 31_000)
    }

    @Test func netWorthReadUsesOpeningBalanceAndExactInclusiveEndDay() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let query = ReportExplorerQuery(
            metric: .netWorth,
            startDay: "2026-01-15",
            endDay: "2026-02-28",
            interval: .month
        )

        let snapshot = try await database.fetchReportExplorer(query: query)

        #expect(snapshot.points.map(\.endingBalance) == [138_501, 138_501])
        #expect(snapshot.totals.openingBalance == 100_000)
        #expect(snapshot.totals.endingBalance == 138_501)
        #expect(snapshot.totals.balanceChange == 38_501)
    }

    @Test func storeBridgesExplorerReadWithoutAddingASecondReportCache() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let store = await LocalFirstActualStore()
        await MainActor.run {
            store.openedBudgetID = "budget"
            store.database = database
        }
        let query = ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month
        )

        let snapshot = try await store.reportExplorerSnapshot(budgetID: "budget", query: query)
        let dashboardCacheIsEmpty = await store.reportsByKey.isEmpty

        #expect(snapshot.totals.expenses == 11_000)
        #expect(dashboardCacheIsEmpty)
    }

    @Test func storeRejectsSameBudgetDatabaseOrSessionReplacement() async throws {
        let firstDatabase = try BudgetDatabase(databaseURL: makeFixture())
        let secondDatabase = try BudgetDatabase(databaseURL: makeFixture())
        let store = await LocalFirstActualStore()
        await MainActor.run {
            store.openedBudgetID = "budget"
            store.database = firstDatabase
            store.budgetSessionGeneration = 7

            #expect(store.reportExplorerSessionIsCurrent(
                database: firstDatabase,
                budgetID: "budget",
                generation: 7
            ))

            store.database = secondDatabase
            #expect(!store.reportExplorerSessionIsCurrent(
                database: firstDatabase,
                budgetID: "budget",
                generation: 7
            ))

            store.database = firstDatabase
            store.budgetSessionGeneration = 8
            #expect(!store.reportExplorerSessionIsCurrent(
                database: firstDatabase,
                budgetID: "budget",
                generation: 7
            ))
        }
    }

    @Test func invalidRangeIsRejectedBeforeSQLiteRead() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let query = ReportExplorerQuery(
            metric: .cashFlow,
            startDay: "2026-02-01",
            endDay: "2026-01-01",
            interval: .day
        )

        await #expect(throws: ReportExplorerError.invalidRange) {
            _ = try await database.fetchReportExplorer(query: query)
        }
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistReportExplorerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    offbudget INTEGER,
                    closed INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    is_income INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    cat_group TEXT,
                    is_income INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );
                CREATE TABLE zero_budgets (
                    month INTEGER,
                    category TEXT,
                    amount INTEGER
                );
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    date INTEGER,
                    amount INTEGER,
                    category TEXT,
                    description TEXT,
                    tombstone INTEGER,
                    parent_id TEXT,
                    isParent INTEGER,
                    isChild INTEGER,
                    transferred_id TEXT
                );

                INSERT INTO accounts VALUES ('checking', 0, 0, 0);
                INSERT INTO accounts VALUES ('savings', 0, 0, 0);
                INSERT INTO accounts VALUES ('brokerage', 1, 0, 0);
                INSERT INTO accounts VALUES ('closed', 0, 1, 0);

                INSERT INTO category_groups VALUES ('income-group', 1, 0);
                INSERT INTO category_groups VALUES ('expense-group', 0, 0);
                INSERT INTO categories VALUES ('salary', 'income-group', 1, 0);
                INSERT INTO categories VALUES ('groceries', 'expense-group', 0, 0);
                INSERT INTO category_mapping VALUES ('salary', 'salary');
                INSERT INTO category_mapping VALUES ('groceries', 'groceries');
                INSERT INTO zero_budgets VALUES (202601, 'groceries', 31000);

                INSERT INTO transactions VALUES ('opening', 'checking', 20260101, 100000, 'salary', NULL, 0, NULL, 0, 0, NULL);
                INSERT INTO transactions VALUES ('income', 'checking', 20260120, 50000, 'salary', NULL, 0, NULL, 0, 0, NULL);
                INSERT INTO transactions VALUES ('expense', 'checking', 20260120, -10000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
                INSERT INTO transactions VALUES ('refund', 'checking', 20260120, 2000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
                INSERT INTO transactions VALUES ('transfer-out', 'checking', 20260121, -2000, NULL, NULL, 0, NULL, 0, 0, 'transfer-in');
                INSERT INTO transactions VALUES ('transfer-in', 'savings', 20260123, 2000, NULL, NULL, 0, NULL, 0, 0, 'transfer-out');
                INSERT INTO transactions VALUES ('split-parent', 'checking', 20260120, -3000, NULL, NULL, 0, NULL, 1, 0, NULL);
                INSERT INTO transactions VALUES ('split-one', 'checking', 20260120, -1000, 'groceries', NULL, 0, 'split-parent', 0, 1, NULL);
                INSERT INTO transactions VALUES ('split-two', 'checking', 20260120, -2000, 'groceries', NULL, 0, 'split-parent', 0, 1, NULL);
                INSERT INTO transactions VALUES ('offbudget', 'brokerage', 20260123, -999, 'groceries', NULL, 0, NULL, 0, 0, NULL);
                INSERT INTO transactions VALUES ('closed-income', 'closed', 20260120, 500, 'salary', NULL, 0, NULL, 0, 0, NULL);
                INSERT INTO transactions VALUES ('deleted', 'checking', 20260125, -777, 'groceries', NULL, 1, NULL, 0, 0, NULL);
                INSERT INTO transactions VALUES ('after-end', 'checking', 20260301, 9000, 'salary', NULL, 0, NULL, 0, 0, NULL);
                """)
        }
        return url
    }
}
