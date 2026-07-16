import Foundation
import GRDB
import SwiftUI
import Testing
@testable import Actualist

@MainActor
@Suite("Reports")
struct ReportsTests {
    @Test func dashboardRangeUsesSixCalendarMonthsAndDateOnlyBoundaries() throws {
        let date = try #require(
            ReportCalendar.gregorianLocal.date(
                from: DateComponents(year: 2026, month: 7, day: 16, hour: 12)
            )
        )
        let range = ReportDateRange.dashboard(through: date)

        #expect(range.anchorMonth == "2026-07")
        #expect(range.startDay == "2026-02-01")
        #expect(range.endDay == "2026-07-16")
        #expect(ReportCalendar.days(in: "2024-02") == 29)
        #expect(ReportCalendar.days(in: "2025-02") == 28)
        #expect(ReportCalendar.days(in: "2026-04") == 30)
        #expect(ReportCalendar.days(in: "2026-07") == 31)
        #expect(ReportCalendar.shiftedMonth("2026-01", by: -1) == "2025-12")
    }

    @Test func localReportsRespectActualTransactionSemantics() async throws {
        let database = try BudgetDatabase(databaseURL: makeReportsFixture())
        let snapshot = try await database.fetchReportsDashboard(range: reportRange)

        #expect(snapshot.netWorth.balance == 1_448_300)
        #expect(snapshot.netWorth.change == 1_328_300)
        #expect(snapshot.netWorth.points.first?.dayID == "2026-02-01")
        #expect(snapshot.netWorth.points.last?.dayID == "2026-07-16")

        #expect(snapshot.cashFlow.income == 500_000)
        #expect(snapshot.cashFlow.expenses == 21_000)
        #expect(snapshot.cashFlow.net == 479_000)
        #expect(snapshot.cashFlow.uncategorized == -700)

        #expect(snapshot.monthComparison.comparisonMonth == "2026-06")
        #expect(snapshot.monthComparison.variance == 109_000)
        #expect(snapshot.monthComparison.points.count == 16)

        #expect(snapshot.budgetOverview.budgetedExpenses == 60_000)
        #expect(snapshot.budgetOverview.actualExpenses == 21_000)
        #expect(snapshot.budgetOverview.variance == -39_000)
        #expect(snapshot.budgetOverview.budgetPoints.count == 31)
        #expect(snapshot.budgetOverview.actualPoints.count == 16)

        #expect(snapshot.threeMonthAverage.currentExpenses == 21_000)
        #expect(snapshot.threeMonthAverage.averageExpenses == 20_000)
        #expect(snapshot.threeMonthAverage.variance == 1_000)
        #expect(snapshot.threeMonthAverage.points.count == 31)
        #expect(snapshot.threeMonthAverage.points[15].current == 21_000)
        #expect(snapshot.threeMonthAverage.points[16].current == nil)
        #expect(snapshot.threeMonthAverage.points.last?.comparison == 20_000)

        #expect(snapshot.transactionCalendar.map(\.month) == ["2026-05", "2026-06", "2026-07"])
        #expect(snapshot.transactionCalendar[0].income == 300_000)
        #expect(snapshot.transactionCalendar[0].expenses == 20_000)
        #expect(snapshot.transactionCalendar[1].income == 400_000)
        #expect(snapshot.transactionCalendar[1].expenses == 30_000)
        #expect(snapshot.transactionCalendar[2].income == 500_000)
        #expect(snapshot.transactionCalendar[2].expenses == 21_000)
        #expect(snapshot.transactionCalendar[2].days.count == 31)
        #expect(snapshot.transactionCalendar[2].days[19].income == 0)
    }

    @Test func storeCachesReportsAndInvalidatesThemExplicitly() async throws {
        let database = try BudgetDatabase(databaseURL: makeReportsFixture())
        let store = LocalFirstActualStore()
        store.openedBudgetID = "budget"
        store.database = database

        #expect(store.cachedReportsDashboard(budgetID: "budget", range: reportRange) == nil)
        let loaded = try await store.refreshReportsDashboard(budgetID: "budget", range: reportRange)
        #expect(store.cachedReportsDashboard(budgetID: "budget", range: reportRange) == loaded)

        store.invalidateReports(budgetID: "budget")
        #expect(store.cachedReportsDashboard(budgetID: "budget", range: reportRange) == nil)
    }

    @Test func mutationAndRemoteReloadPathsInvalidateReportCache() async throws {
        let database = try BudgetDatabase(databaseURL: makeReportsFixture())
        let store = LocalFirstActualStore()
        store.openedBudgetID = "budget"
        store.database = database

        _ = try await store.refreshReportsDashboard(budgetID: "budget", range: reportRange)
        try await store.reloadAfterBudgetMutation(database: database, budgetID: "budget")
        #expect(store.cachedReportsDashboard(budgetID: "budget", range: reportRange) == nil)

        _ = try await store.refreshReportsDashboard(budgetID: "budget", range: reportRange)
        try await store.reloadAfterRemoteSync(database: database, budgetID: "budget")
        #expect(store.cachedReportsDashboard(budgetID: "budget", range: reportRange) == nil)

        _ = try await store.refreshReportsDashboard(budgetID: "budget", range: reportRange)
        try await store.reloadAfterAccountMutation(database: database, budgetID: "budget")
        #expect(store.cachedReportsDashboard(budgetID: "budget", range: reportRange) == nil)
    }

    @Test func viewModelUsesCacheThenLocalRemoteAndLocalRefresh() async throws {
        let cached = makeSnapshot(netWorth: 100_000)
        let local = makeSnapshot(netWorth: 110_000)
        let synced = makeSnapshot(netWorth: 125_000)
        let repository = FakeReportsRepository(cached: cached, refreshed: [local, synced])
        let viewModel = ReportsViewModel()
        var remoteRefreshCount = 0

        await viewModel.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: false,
            now: try reportNow(),
            refreshRemote: { remoteRefreshCount += 1 }
        )

        #expect(repository.refreshCount == 2)
        #expect(remoteRefreshCount == 1)
        #expect(viewModel.snapshot == synced)
        #expect(viewModel.displaySnapshot == synced)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isLoading)
        #expect(!viewModel.isRefreshing)
    }

    @Test func viewModelKeepsCachedReportsWhenLocalReadFails() async throws {
        let cached = makeSnapshot(netWorth: 100_000)
        let repository = FakeReportsRepository(cached: cached, error: ReportsTestError.failed)
        let viewModel = ReportsViewModel()

        await viewModel.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: false,
            now: try reportNow()
        )

        #expect(viewModel.snapshot == cached)
        #expect(viewModel.displaySnapshot == cached)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isLoading)
    }

    @Test func emptySnapshotIsPublishedAsAnEmptyReportState() async throws {
        let empty = makeSnapshot(netWorth: 0, hasData: false)
        let repository = FakeReportsRepository(cached: nil, refreshed: [empty, empty])
        let viewModel = ReportsViewModel()

        await viewModel.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: false,
            now: try reportNow()
        )

        #expect(viewModel.displaySnapshot?.hasData == false)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isLoading)
    }

    @Test func dashboardRendersAllCardsAtPhoneWidthInAccessibilityModes() async throws {
        let raw = makeSnapshot(netWorth: 123_456)
        let repository = FakeReportsRepository(cached: nil, refreshed: [raw, raw])
        let viewModel = ReportsViewModel()
        await viewModel.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: true,
            now: try reportNow()
        )
        let snapshot = try #require(viewModel.displaySnapshot)
        let content = ReportsDashboardContent(snapshot: snapshot, viewModel: viewModel)
            .frame(width: 390)
            .padding(14)
            .background(ActualistTheme.background)
            .environment(\.actualistDensity, .compact)
            .environment(\.dynamicTypeSize, .accessibility2)
            .transaction { $0.disablesAnimations = true }
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: 418, height: nil)

        let image = try #require(renderer.uiImage)
        #expect(image.size.width == 418)
        #expect(image.size.height > 1_000)
    }

    @Test func privacyModeSanitizesChartsLabelsAndAccessibilityInputs() async throws {
        let raw = makeSnapshot(netWorth: 123_456)
        let repository = FakeReportsRepository(cached: nil, refreshed: [raw, raw])
        let viewModel = ReportsViewModel()

        await viewModel.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: true,
            now: try reportNow()
        )

        let privateSnapshot = try #require(viewModel.displaySnapshot)
        #expect(privateSnapshot != raw)
        #expect(privateSnapshot.netWorth.balance != raw.netWorth.balance)
        #expect(privateSnapshot.cashFlow.income != raw.cashFlow.income)
        #expect(privateSnapshot.transactionCalendar[0].days[1].income == 0)
        #expect(!viewModel.netWorthAccessibility.contains("1234.56"))

        viewModel.updatePrivacyMode(false)
        #expect(viewModel.displaySnapshot == raw)
    }

    @Test func reportTonesUseMoneyMeaningNotRawSignAlone() async throws {
        let raw = makeSnapshot(netWorth: 100_000)
        let repository = FakeReportsRepository(cached: nil, refreshed: [raw, raw])
        let viewModel = ReportsViewModel()
        await viewModel.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: false,
            now: try reportNow()
        )

        #expect(viewModel.cashFlowTone == .positive)
        #expect(viewModel.monthComparisonTone == .positive)
        #expect(viewModel.budgetOverviewTone == .positive)
        #expect(viewModel.threeMonthAverageTone == .danger)
    }

    @Test func nativeTabOrderReplacesSettingsWithReports() {
        #expect(AppTab.allCases == [.budget, .spending, .accounts, .reports])
        #expect(AppTab.reports.title == "Reports")
        #expect(AppTab.reports.symbolName == "chart.xyaxis.line")
    }

    @Test func longHistoryAggregateCompletesWithoutPerDayQueries() async throws {
        let url = try makeReportsFixture(extraTransactionCount: 5_000)
        let database = try BudgetDatabase(databaseURL: url)
        let clock = ContinuousClock()
        let started = clock.now

        let snapshot = try await database.fetchReportsDashboard(range: reportRange)

        #expect(snapshot.netWorth.points.count == 166)
        #expect(started.duration(to: clock.now) < .seconds(5))
    }

    private var reportRange: ReportDateRange {
        ReportDateRange(anchorMonth: "2026-07", startDay: "2026-02-01", endDay: "2026-07-16")
    }

    private func reportNow() throws -> Date {
        try #require(
            ReportCalendar.gregorianLocal.date(
                from: DateComponents(year: 2026, month: 7, day: 16, hour: 12)
            )
        )
    }

    private func makeReportsFixture(extraTransactionCount: Int = 0) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistReportsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    offbudget INTEGER,
                    closed INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    is_income INTEGER,
                    hidden INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    cat_group TEXT,
                    is_income INTEGER,
                    hidden INTEGER,
                    tombstone INTEGER
                );
                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT
                );
                CREATE TABLE zero_budgets (
                    month INTEGER,
                    category TEXT,
                    amount INTEGER,
                    carryover INTEGER
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
                    transferred_id TEXT
                );

                INSERT INTO accounts VALUES ('checking', 'Checking', 0, 0, 0);
                INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0);
                INSERT INTO accounts VALUES ('brokerage', 'Brokerage', 1, 0, 0);
                INSERT INTO accounts VALUES ('closed', 'Closed Account', 0, 1, 0);
                INSERT INTO accounts VALUES ('deleted', 'Deleted Account', 0, 0, 1);

                INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0);
                INSERT INTO category_groups VALUES ('expense-group', 'Expenses', 0, 0, 0);
                INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0);
                INSERT INTO categories VALUES ('groceries', 'Groceries', 'expense-group', 0, 0, 0);
                INSERT INTO categories VALUES ('hidden-expense', 'Hidden Expense', 'expense-group', 0, 1, 0);
                INSERT INTO categories VALUES ('offbudget-transfer', 'Off-Budget Transfer', 'expense-group', 0, 0, 0);
                INSERT INTO categories VALUES ('deleted-category', 'Deleted Category', 'expense-group', 0, 0, 1);
                INSERT INTO category_mapping VALUES ('offbudget-transfer', 'offbudget-transfer');

                INSERT INTO payees VALUES ('same-transfer', 'Savings', 'savings');
                INSERT INTO payees VALUES ('offbudget-payee', 'Brokerage', 'brokerage');

                INSERT INTO zero_budgets VALUES (202607, 'salary', 999999, 0);
                INSERT INTO zero_budgets VALUES (202607, 'groceries', 50000, 0);
                INSERT INTO zero_budgets VALUES (202607, 'hidden-expense', 10000, 0);
                INSERT INTO zero_budgets VALUES (202607, 'deleted-category', 77777, 0);

                INSERT INTO transactions VALUES ('start-checking', 'checking', 20260101, 100000, NULL, NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('start-closed', 'closed', 20260101, 20000, NULL, NULL, 0, NULL, 0, NULL);

                INSERT INTO transactions VALUES ('apr-income', 'checking', 20260401, 200000, 'salary', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('apr-expense', 'checking', 20260405, -10000, 'groceries', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('may-income', 'checking', 20260501, 300000, 'salary', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('may-expense', 'checking', 20260505, -20000, 'groceries', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('jun-income', 'checking', 20260601, 400000, 'salary', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('jun-expense', 'checking', 20260605, -30000, 'groceries', NULL, 0, NULL, 0, NULL);

                INSERT INTO transactions VALUES ('jul-income', 'checking', 20260701, 500000, 'salary', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('jul-grocery', 'checking', 20260702, -10000, 'groceries', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('jul-refund', 'checking', 20260703, 2000, 'groceries', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('same-transfer-out', 'checking', 20260704, -5000, NULL, 'same-transfer', 0, NULL, 0, 'same-transfer-in');
                INSERT INTO transactions VALUES ('same-transfer-in', 'savings', 20260704, 5000, NULL, NULL, 0, NULL, 0, 'same-transfer-out');
                INSERT INTO transactions VALUES ('offbudget-transfer-out', 'checking', 20260705, -10000, 'offbudget-transfer', 'offbudget-payee', 0, NULL, 0, 'offbudget-transfer-in');
                INSERT INTO transactions VALUES ('offbudget-transfer-in', 'brokerage', 20260705, 10000, NULL, NULL, 0, NULL, 0, 'offbudget-transfer-out');

                INSERT INTO transactions VALUES ('split-parent', 'checking', 20260706, -3000, NULL, NULL, 0, NULL, 1, NULL);
                INSERT INTO transactions VALUES ('split-grocery', 'checking', 20260706, -1000, 'groceries', NULL, 0, 'split-parent', 0, NULL);
                INSERT INTO transactions VALUES ('split-hidden', 'checking', 20260706, -2000, 'hidden-expense', NULL, 0, 'split-parent', 0, NULL);

                INSERT INTO transactions VALUES ('uncategorized', 'checking', 20260707, -700, NULL, NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('tombstoned', 'checking', 20260708, -999, 'groceries', NULL, 1, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('dead-parent', 'checking', 20260708, -777, NULL, NULL, 1, NULL, 1, NULL);
                INSERT INTO transactions VALUES ('dead-child', 'checking', 20260708, -777, 'groceries', NULL, 0, 'dead-parent', 0, NULL);
                INSERT INTO transactions VALUES ('deleted-account-row', 'deleted', 20260709, 99999, 'salary', NULL, 0, NULL, 0, NULL);
                INSERT INTO transactions VALUES ('future-row', 'checking', 20260720, 99999, 'salary', NULL, 0, NULL, 0, NULL);
                """)

            if extraTransactionCount > 0 {
                for index in 0..<extraTransactionCount {
                    let month = (index % 6) + 2
                    let day = (index % 28) + 1
                    let date = 20260000 + month * 100 + day
                    try db.execute(
                        sql: "INSERT INTO transactions VALUES (?, 'checking', ?, -100, 'groceries', NULL, 0, NULL, 0, NULL)",
                        arguments: ["bulk-\(index)", date]
                    )
                }
            }
        }
        return url
    }

    private func makeSnapshot(netWorth: Int, hasData: Bool = true) -> ReportsDashboardSnapshot {
        let point1 = ReportValuePoint(dayID: "2026-07-01", value: netWorth - 10_000)
        let point2 = ReportValuePoint(dayID: "2026-07-16", value: netWorth)
        let comparisonPoints = [
            DailyComparisonPoint(day: 1, current: 10_000, comparison: 8_000),
            DailyComparisonPoint(day: 2, current: 20_000, comparison: 15_000)
        ]
        let calendarDays = [
            TransactionCalendarDay(dayID: "2026-07-01", day: 1, income: 50_000, expenses: 10_000),
            TransactionCalendarDay(dayID: "2026-07-02", day: 2, income: 0, expenses: 0)
        ]
        return ReportsDashboardSnapshot(
            range: reportRange,
            hasData: hasData,
            netWorth: NetWorthReport(points: [point1, point2], balance: netWorth, change: 10_000),
            cashFlow: CashFlowSummary(month: "2026-07", income: 50_000, expenses: 10_000, net: 40_000, uncategorized: 0),
            monthComparison: MonthComparisonReport(
                currentMonth: "2026-07",
                comparisonMonth: "2026-06",
                points: comparisonPoints,
                variance: 5_000
            ),
            budgetOverview: BudgetOverviewReport(
                month: "2026-07",
                actualPoints: [ReportValuePoint(dayID: "2026-07-16", value: 20_000)],
                budgetPoints: [ReportValuePoint(dayID: "2026-07-31", value: 30_000)],
                actualExpenses: 20_000,
                budgetedExpenses: 30_000,
                variance: -10_000
            ),
            threeMonthAverage: ThreeMonthAverageReport(
                month: "2026-07",
                points: comparisonPoints,
                currentExpenses: 20_000,
                averageExpenses: 15_000,
                variance: 5_000
            ),
            transactionCalendar: [
                TransactionCalendarMonth(
                    month: "2026-07",
                    leadingBlankCount: 3,
                    days: calendarDays,
                    income: 50_000,
                    expenses: 10_000
                )
            ]
        )
    }
}

private enum ReportsTestError: Error {
    case failed
}

@MainActor
private final class FakeReportsRepository: ReportsRepositoryProtocol {
    let cached: ReportsDashboardSnapshot?
    var refreshed: [ReportsDashboardSnapshot]
    let error: Error?
    var refreshCount = 0

    init(
        cached: ReportsDashboardSnapshot?,
        refreshed: [ReportsDashboardSnapshot] = [],
        error: Error? = nil
    ) {
        self.cached = cached
        self.refreshed = refreshed
        self.error = error
    }

    func cachedReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) -> ReportsDashboardSnapshot? {
        cached
    }

    func refreshReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) async throws -> ReportsDashboardSnapshot {
        refreshCount += 1
        if let error { throw error }
        guard !refreshed.isEmpty else { throw ReportsTestError.failed }
        return refreshed.removeFirst()
    }
}
