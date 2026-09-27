import Foundation
import Testing
@testable import Actualist

extension ReportExplorerTests {
    @Test func emptyAndDeletedCategorySelectionsRespectExplicitUncategorizedChoice() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture(extraSQL: """
            INSERT INTO transactions VALUES (
                'uncategorized-normal', 'checking', 20260120, -321,
                NULL, NULL, 0, NULL, 0, 0, NULL
            );
            """))

        for selection in [ReportFilterSelection.only([]), .only(["deleted-category"])] {
            let excluded = try await database.fetchReportExplorer(query: ReportExplorerQuery(
                metric: .spending,
                startDay: "2026-01-20",
                endDay: "2026-01-23",
                interval: .day,
                filters: categoryFilters(selection: selection, includesUncategorized: false)
            ))
            let included = try await database.fetchReportExplorer(query: ReportExplorerQuery(
                metric: .spending,
                startDay: "2026-01-20",
                endDay: "2026-01-23",
                interval: .day,
                filters: categoryFilters(selection: selection, includesUncategorized: true)
            ))

            #expect(excluded.totals.expenses == 0)
            #expect(included.totals.expenses == 321)
            let request = try #require(included.drilldown.request)
            #expect(request.query.conditions.contains(.category(.equals(nil))))
            let result = try await database.fetchTransactionDrilldown(request)
            #expect(result.contributingTransactions.compactMap(\.id) == ["uncategorized-normal"])
        }
    }

    @Test func everyActivityMetricUsesItsAuthoritativeContributorSet() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture(extraSQL: """
            INSERT INTO transactions VALUES ('history-selected', 'checking', 20251210, -9000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('history-wrong-account', 'savings', 20251110, -6000, 'groceries', NULL, 0, NULL, 0, 0, NULL);
            INSERT INTO transactions VALUES ('history-wrong-category', 'checking', 20251010, -3000, 'salary', NULL, 0, NULL, 0, 0, NULL);
            """))

        let cashFlow = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .cashFlow,
            startDay: "2026-01-20",
            endDay: "2026-01-20",
            interval: .day
        ))
        let cashResult = try await drilldown(cashFlow, database: database)
        let cashContributorTotal = try ReportArithmetic.sum(
            cashResult.contributingTransactions.compactMap(\.amount)
        )
        #expect(cashFlow.totals.net == cashContributorTotal)

        let budgetOverview = try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .budgetOverview,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month
        ))
        let budgetResult = try await drilldown(budgetOverview, database: database)
        let budgetContributorTotal = try ReportArithmetic.sum(
            budgetResult.contributingTransactions.compactMap(\.amount)
        )
        #expect(budgetOverview.totals.expenses == 0 - budgetContributorTotal)

        let averageQuery = ReportExplorerQuery(
            metric: .spendingAverage,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .day,
            filters: ReportExplorerFilters(
                accounts: .only(["checking"]),
                categories: .only(["groceries"]),
                includesOffBudget: false,
                includesHiddenCategories: true,
                includesUncategorized: false
            )
        )
        let average = try await database.fetchReportExplorer(query: averageQuery)
        let currentResult = try await drilldown(average, database: database)
        let currentContributorTotal = try ReportArithmetic.sum(
            currentResult.contributingTransactions.compactMap(\.amount)
        )
        #expect(average.totals.expenses == 0 - currentContributorTotal)

        let comparison = try #require(averageQuery.spendingAverageComparison)
        let historyRequest = try await database.reportExplorerTransactionRequest(
            query: averageQuery,
            startDay: try #require(comparison.history.first).startDay,
            endDay: try #require(comparison.history.last).endDay,
            catalog: average.filterCatalog
        )
        let historyResult = try await database.fetchTransactionDrilldown(historyRequest)
        let historySpending = 0 - (try ReportArithmetic.sum(
            historyResult.contributingTransactions.compactMap(\.amount)
        ))
        #expect(historyRequest.query.signature == average.historyQuerySignature)
        #expect(historyResult.contributingTransactions.compactMap(\.id) == ["history-selected"])
        #expect(average.totals.averageSpending == historySpending / 3)
        #expect(average.totals.averageSpending == 3_000)
    }

    @Test func netWorthAccountSubsetsHandleEmptyDeletedAndOffBudgetWithoutDrilldown() async throws {
        let database = try BudgetDatabase(databaseURL: makeFixture())
        let checking = try await netWorth(
            database: database,
            accounts: .only(["checking"]),
            includesOffBudget: false
        )
        let empty = try await netWorth(
            database: database,
            accounts: .only([]),
            includesOffBudget: false
        )
        let deleted = try await netWorth(
            database: database,
            accounts: .only(["deleted-account"]),
            includesOffBudget: false
        )
        let blockedOffBudget = try await netWorth(
            database: database,
            accounts: .only(["brokerage"]),
            includesOffBudget: false
        )
        let includedOffBudget = try await netWorth(
            database: database,
            accounts: .only(["brokerage"]),
            includesOffBudget: true
        )

        #expect(checking.totals.endingBalance == 137_000)
        #expect(empty.totals.endingBalance == 0)
        #expect(deleted.totals.endingBalance == 0)
        #expect(blockedOffBudget.totals.endingBalance == 0)
        #expect(includedOffBudget.totals.endingBalance == -999)
        for snapshot in [checking, empty, deleted, blockedOffBudget, includedOffBudget] {
            #expect(snapshot.drilldown == .unavailable(.balanceSnapshot))
            #expect(snapshot.activityQuerySignature == nil)
        }
    }

    private func categoryFilters(
        selection: ReportFilterSelection,
        includesUncategorized: Bool
    ) -> ReportExplorerFilters {
        ReportExplorerFilters(
            accounts: .only(["checking"]),
            categories: selection,
            includesOffBudget: false,
            includesHiddenCategories: true,
            includesUncategorized: includesUncategorized
        )
    }

    private func drilldown(
        _ snapshot: ReportExplorerSnapshot,
        database: BudgetDatabase
    ) async throws -> TransactionDrilldownResult {
        try await database.fetchTransactionDrilldown(try #require(snapshot.drilldown.request))
    }

    private func netWorth(
        database: BudgetDatabase,
        accounts: ReportFilterSelection,
        includesOffBudget: Bool
    ) async throws -> ReportExplorerSnapshot {
        try await database.fetchReportExplorer(query: ReportExplorerQuery(
            metric: .netWorth,
            startDay: "2026-01-01",
            endDay: "2026-01-31",
            interval: .month,
            filters: ReportExplorerFilters(
                accounts: accounts,
                categories: .all,
                includesOffBudget: includesOffBudget,
                includesHiddenCategories: true,
                includesUncategorized: true
            )
        ))
    }
}
