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

        let average = ReportExplorerQuery(
            metric: .spendingAverage,
            startDay: "2026-01-01",
            endDay: "2026-01-15",
            interval: .day
        )
        #expect(average.spendingAverageComparison == ReportSpendingAverageComparison(
            comparison: ReportExplorerPeriod(startDay: "2026-01-01", endDay: "2026-01-15"),
            history: [
                ReportExplorerPeriod(startDay: "2025-10-01", endDay: "2025-10-31"),
                ReportExplorerPeriod(startDay: "2025-11-01", endDay: "2025-11-30"),
                ReportExplorerPeriod(startDay: "2025-12-01", endDay: "2025-12-31"),
            ]
        ))
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
            "threeMonthAverage|spendingAverage|monthToDate|day",
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

    @Test func budgetOverviewDailyDefaultIsCumulativeFromTheInclusiveRangeStart() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture(extraSQL: """
            INSERT INTO transactions VALUES (
                'budget-day-two', 'checking', 20260102, -2000,
                'groceries', NULL, 0, NULL, 0, 0, NULL
            );
            """))
        let monthToDate = ReportExplorerQuery(
            metric: .budgetOverview,
            startDay: "2026-01-01",
            endDay: "2026-01-03",
            interval: .day
        )

        let snapshot = try await database.fetchReportExplorer(query: monthToDate)

        #expect(snapshot.points.map(\.expenses) == [0, 2_000, 2_000])
        #expect(snapshot.points.map(\.budgeted) == [1_000, 2_000, 3_000])
        #expect(snapshot.totals.expenses == 2_000)
        #expect(snapshot.totals.budgeted == 3_000)

        let partialRange = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .budgetOverview,
            startDay: "2026-01-02",
            endDay: "2026-01-03",
            interval: .day
        ))
        #expect(partialRange.points.map(\.expenses) == [2_000, 2_000])
        #expect(partialRange.points.map(\.budgeted) == [1_000, 2_000])
        #expect(partialRange.totals.expenses == 2_000)
        #expect(partialRange.totals.budgeted == 2_000)

        let fullMonth = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .budgetOverview,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .day
        ))
        #expect(fullMonth.points.count == 28)
        #expect(fullMonth.points.last?.period == ReportExplorerPeriod(
            startDay: "2026-01-28",
            endDay: "2026-01-31"
        ))
        #expect(fullMonth.points.last?.budgeted == 31_000)
        #expect(fullMonth.points.last?.expenses == 13_000)
    }

    @Test func spendingAverageUsesThreePriorMonthsAndCorrespondingDayCutoffs() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture(extraSQL: """
            INSERT INTO transactions VALUES ('oct-base', 'checking', 20251001, -30000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('nov-base', 'checking', 20251101, -30000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('dec-base', 'checking', 20251201, -30000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('oct-end', 'checking', 20251031, -3000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('nov-end', 'checking', 20251130, -3000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('dec-end', 'checking', 20251231, -3000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            """))

        let monthToDate = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spendingAverage,
            startDay: "2026-01-01",
            endDay: "2026-01-15",
            interval: .day
        ))
        #expect(monthToDate.points.last?.expenses == 0)
        #expect(monthToDate.points.last?.comparison == 30_000)
        #expect(monthToDate.totals.averageSpending == 30_000)

        let throughDay30 = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spendingAverage,
            startDay: "2026-01-01",
            endDay: "2026-01-30",
            interval: .day
        ))
        #expect(throughDay30.points.last?.period == ReportExplorerPeriod(
            startDay: "2026-01-28",
            endDay: "2026-01-30"
        ))
        #expect(throughDay30.points.last?.comparison == 33_000)

        let throughDay31 = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spendingAverage,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .day
        ))
        #expect(throughDay31.points.last?.expenses == 11_000)
        #expect(throughDay31.points.last?.comparison == 33_000)
    }

    @Test func spendingAverageHasZeroBenchmarkWhenAllThreeHistoryMonthsAreEmpty() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture(extraSQL: """
            INSERT INTO transactions VALUES (
                'current-only', 'checking', 20260102, -5000,
                'groceries', NULL, 0, NULL, 0, 0, NULL
            );
            """))
        let snapshot = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spendingAverage,
            startDay: "2026-01-01",
            endDay: "2026-01-15",
            interval: .day
        ))

        #expect(snapshot.points.last?.expenses == 5_000)
        #expect(snapshot.points.last?.comparison == 0)
        #expect(snapshot.totals.averageSpending == 0)
        #expect(snapshot.hasData)
    }

    @Test func spendingAverageRejectsCrossMonthComparisonRanges() async throws {
        let query = ReportExplorerQuery(
            metric: .spendingAverage,
            startDay: "2025-11-01",
            endDay: "2026-01-31",
            interval: .day
        )

        #expect(query.validationError == .spendingAverageRequiresSingleMonth)
        #expect(!query.hasValidRange)
        #expect(query.periods.isEmpty)
        #expect(query.spendingAverageComparison == nil)

        let database = try BudgetDatabase(databaseURL: makeFixture())
        await #expect(throws: ReportExplorerError.spendingAverageRequiresSingleMonth) {
            _ = try await database.fetchReportExplorer(query: query)
        }
    }

    @Test func netWorthRejectsActivityOnlyCategoryVisibilityFilters() {
        let query = ReportExplorerQuery(
            metric: .netWorth,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month,
            filters: ReportExplorerFilters(
                accounts: .all,
                categories: .all,
                includesOffBudget: false,
                includesHiddenCategories: false,
                includesUncategorized: true
            )
        )

        #expect(query.validationError == .unsupportedNetWorthCategoryFilter)
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

        #expect(snapshot.points.map(\.endingBalance) == [139_500, 139_500])
        #expect(snapshot.totals.openingBalance == 100_000)
        #expect(snapshot.totals.endingBalance == 139_500)
        #expect(snapshot.totals.balanceChange == 39_500)
        #expect(snapshot.drilldown == .unavailable(.balanceSnapshot))
    }

    @Test func filtersUseOneStructuredQueryAndTotalsSumOnlyItsContributors() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture(extraSQL: """
            INSERT INTO categories VALUES ('hidden-food', 'Hidden Food', 'expense-group', 0, 1, 0);
            INSERT INTO category_mapping VALUES ('legacy-groceries', 'groceries');
            INSERT INTO transactions VALUES ('hidden-expense', 'checking', 20260120, -700, 'hidden-food', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('mapped-expense', 'checking', 20260120, -500, 'legacy-groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('offbudget-grocery', 'brokerage', 20260120, -900, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            """))
        let filters = ReportExplorerFilters(
            accounts: .only(["checking"]),
            categories: .only(["groceries"]),
            includesOffBudget: false,
            includesHiddenCategories: false,
            includesUncategorized: false
        )
        let snapshot = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-20",
            endDay: "2026-01-23",
            interval: .day,
            filters: filters
        ))
        let request = try #require(snapshot.drilldown.request)
        let result = try await database.fetchTransactionDrilldown(request)
        let signedContributorTotal = try ReportArithmetic.sum(
            result.contributingTransactions.compactMap(\.amount)
        )

        #expect(snapshot.totals.expenses == 11_500)
        #expect(snapshot.totals.expenses == 0 - signedContributorTotal)
        #expect(result.querySignature == request.query.signature)
        #expect(result.contributingTransactions.compactMap(\.id).sorted() == [
            "expense", "mapped-expense", "refund", "split-one", "split-two",
        ])
        #expect(result.contributingTransactions.first { $0.id == "mapped-expense" }?.category == "groceries")
        #expect(result.attachedContextTransactionIDs == ["split-parent"])
        #expect(snapshot.filterCatalog.accounts.contains { $0.id == "closed" && $0.isClosed })
        #expect(snapshot.filterCatalog.categories.contains { $0.id == "hidden-food" && $0.isHidden })

        let hiddenExcluded = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-20",
            endDay: "2026-01-20",
            interval: .day,
            filters: ReportExplorerFilters(
                accounts: .only(["checking"]),
                categories: .only(["hidden-food"]),
                includesOffBudget: false,
                includesHiddenCategories: false,
                includesUncategorized: false
            )
        ))
        let hiddenIncluded = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-20",
            endDay: "2026-01-20",
            interval: .day,
            filters: ReportExplorerFilters(
                accounts: .only(["checking"]),
                categories: .only(["hidden-food"]),
                includesOffBudget: false,
                includesHiddenCategories: true,
                includesUncategorized: false
            )
        ))
        #expect(hiddenExcluded.totals.expenses == 0)
        #expect(hiddenIncluded.totals.expenses == 700)
    }

    @Test func emptyExplicitSelectionsMatchNothingAndOffBudgetRequiresOptIn() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let empty = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month,
            filters: ReportExplorerFilters(
                accounts: .only([]),
                categories: .all,
                includesOffBudget: true,
                includesHiddenCategories: true,
                includesUncategorized: true
            )
        ))
        #expect(empty.totals.expenses == 0)
        #expect(empty.drilldown == .unavailable(.noContributingTransactions))
        #expect(empty.activityQuerySignature != nil)

        let optedIn = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-23",
            endDay: "2026-01-23",
            interval: .day,
            filters: ReportExplorerFilters(
                accounts: .only(["brokerage"]),
                categories: .all,
                includesOffBudget: true,
                includesHiddenCategories: true,
                includesUncategorized: true
            )
        ))
        #expect(optedIn.totals.expenses == 999)
    }

    @Test func closedAccountsRemainSelectableWhileDeletedReferencesMatchNothing() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let closed = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .cashFlow,
            startDay: "2026-01-20",
            endDay: "2026-01-20",
            interval: .day,
            filters: ReportExplorerFilters(
                accounts: .only(["closed"]),
                categories: .all,
                includesOffBudget: false,
                includesHiddenCategories: true,
                includesUncategorized: true
            )
        ))
        let deletedReference = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spending,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month,
            filters: ReportExplorerFilters(
                accounts: .only(["deleted-account"]),
                categories: .all,
                includesOffBudget: false,
                includesHiddenCategories: true,
                includesUncategorized: true
            )
        ))

        #expect(closed.totals.income == 500)
        #expect(deletedReference.totals.expenses == 0)
    }

    @Test func budgetOverviewAccountSubsetFiltersSpendingButNotCategoryScopedBudget() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let snapshot = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .budgetOverview,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month,
            filters: ReportExplorerFilters(
                accounts: .only(["savings"]),
                categories: .only(["groceries"]),
                includesOffBudget: false,
                includesHiddenCategories: true,
                includesUncategorized: true
            )
        ))

        #expect(snapshot.totals.expenses == -2_000)
        #expect(snapshot.totals.budgeted == 31_000)
    }

    @Test func budgetOverviewIgnoresTransferredSourceIncomeAndDeletedBudgetRows() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture(extraSQL: """
            INSERT INTO categories VALUES ('old-category', 'Old', 'expense-group', 0, 0, 1);
            INSERT INTO category_mapping VALUES ('old-category', 'groceries');
            INSERT INTO zero_budgets VALUES (202601, 'old-category', 5000);
            INSERT INTO zero_budgets VALUES (202601, 'salary', 90000);
            """))
        let snapshot = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .budgetOverview,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month
        ))

        #expect(snapshot.totals.budgeted == 31_000)
    }

    @Test func spendingAverageKeepsCurrentDrilldownSeparateFromFilteredHistoryQuery() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture(extraSQL: """
            INSERT INTO transactions VALUES ('current', 'checking', 20260110, -1200, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('oct', 'checking', 20251010, -3000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('nov', 'checking', 20251110, -6000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('dec', 'checking', 20251210, -9000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            """))
        let snapshot = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .spendingAverage,
            startDay: "2026-01-01",
            endDay: "2026-01-15",
            interval: .day,
            filters: ReportExplorerFilters(
                accounts: .only(["checking"]),
                categories: .only(["groceries"]),
                includesOffBudget: false,
                includesHiddenCategories: true,
                includesUncategorized: false
            )
        ))
        let current = try #require(snapshot.drilldown.request)
        let historySignature = try #require(snapshot.historyQuerySignature)

        #expect(current.query.signature != historySignature)
        #expect(snapshot.activityQuerySignature == current.query.signature)
        #expect(snapshot.totals.averageSpending == 6_000)
        let result = try await database.fetchTransactionDrilldown(current)
        #expect(result.contributingTransactions.compactMap(\.id) == ["current"])
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
        let request = try #require(snapshot.drilldown.request)
        let drilldown = try await store.reportTransactionDrilldown(
            budgetID: "budget",
            request: request
        )
        let dashboardCacheIsEmpty = await store.reportsByKey.isEmpty

        #expect(snapshot.totals.expenses == 11_000)
        #expect(drilldown.loaded.querySignature == snapshot.activityQuerySignature)
        #expect(drilldown.loaded.contributingTransactionIDs == drilldown.contributingTransactionIDs)
        let contextIDs = try #require(drilldown.loaded.attachedContextTransactionIDs)
        let matchingIDs = try #require(drilldown.loaded.matchingTransactionIDs)
        #expect(contextIDs.isEmpty)
        #expect(matchingIDs.contains("split-parent"))
        #expect(!drilldown.contributingTransactionIDs.contains("split-parent"))
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

    func makeFixture(extraSQL: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistReportExplorerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER,
                    closed INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    is_income INTEGER,
                    hidden INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    cat_group TEXT,
                    is_income INTEGER,
                    hidden INTEGER,
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

                INSERT INTO accounts VALUES ('checking', 'Checking', 0, 0, 0);
                INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0);
                INSERT INTO accounts VALUES ('brokerage', 'Brokerage', 1, 0, 0);
                INSERT INTO accounts VALUES ('closed', 'Closed', 0, 1, 0);

                INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0);
                INSERT INTO category_groups VALUES ('expense-group', 'Expenses', 0, 0, 0);
                INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0);
                INSERT INTO categories VALUES ('groceries', 'Groceries', 'expense-group', 0, 0, 0);
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
            if !extraSQL.isEmpty {
                try db.execute(sql: extraSQL)
            }
        }
        return url
    }
}
