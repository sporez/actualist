import Foundation
import Testing
@testable import Actualist

@MainActor
struct ReportsViewModelStaleLoadTests {
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    @Test func olderLoadFinishingLateDoesNotReplaceTheNewerBudgetsSnapshot() async {
        let repository = GatedReportsRepository(netWorth: ["a": 100_000, "b": 200_000], gated: "a")
        let model = ReportsViewModel()
        let older = Task {
            await model.load(budgetID: "a", repository: repository, privacyModeEnabled: false, now: now)
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            repository.entered.trip()
            repository.release.trip()
        }
        defer { deadline.cancel(); older.cancel(); repository.release.trip() }
        await repository.entered.wait()

        await model.load(budgetID: "b", repository: repository, privacyModeEnabled: false, now: now)
        #expect(model.snapshot?.netWorth.balance == 200_000)

        repository.release.trip()
        await older.value

        // A's response has completed by now; B must still be on screen.
        #expect(model.snapshot?.netWorth.balance == 200_000)
        #expect(model.displaySnapshot?.netWorth.balance == 200_000)
        #expect(model.snapshotBudgetID == "b")
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    @Test func switchingBudgetsDoesNotKeepShowingTheOldBudgetsSnapshotWhileLoading() async {
        let repository = GatedReportsRepository(netWorth: ["a": 100_000, "b": 200_000], gated: "b")
        let model = ReportsViewModel()
        await model.load(budgetID: "a", repository: repository, privacyModeEnabled: false, now: now)
        #expect(model.snapshotBudgetID == "a")

        let switching = Task {
            await model.load(budgetID: "b", repository: repository, privacyModeEnabled: false, now: now)
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            repository.entered.trip()
            repository.release.trip()
        }
        defer { deadline.cancel(); switching.cancel(); repository.release.trip() }
        await repository.entered.wait()

        #expect(model.snapshot == nil)
        #expect(model.displaySnapshot == nil)
        #expect(model.snapshotBudgetID == nil)
        #expect(model.isLoading)

        repository.release.trip()
        await switching.value
        #expect(model.snapshotBudgetID == "b")
        #expect(model.snapshot?.netWorth.balance == 200_000)
    }

    @Test func earlierRefreshFinishingFirstDoesNotClearTheNewerRefreshesFlag() async {
        let model = ReportsViewModel()
        let olderEntered = TestLatch()
        let olderRelease = TestLatch()
        let newerEntered = TestLatch()
        let newerRelease = TestLatch()
        let older = Task {
            await model.refresh(sync: {}, reload: {
                olderEntered.trip()
                await olderRelease.wait()
            })
        }
        let newer = Task {
            await model.refresh(sync: {}, reload: {
                newerEntered.trip()
                await newerRelease.wait()
            })
        }
        func releaseAll() {
            olderEntered.trip(); newerEntered.trip(); olderRelease.trip(); newerRelease.trip()
        }
        defer { older.cancel(); newer.cancel(); releaseAll() }
        let bothStarted = await olderEntered.wait(timeout: .seconds(5), onTimeout: releaseAll)
        let newerStarted = await newerEntered.wait(timeout: .seconds(5), onTimeout: releaseAll)
        #expect(bothStarted && newerStarted)

        olderRelease.trip()
        await older.value
        #expect(model.isRefreshing)

        newerRelease.trip()
        await newer.value
        #expect(!model.isRefreshing)
    }
}

@MainActor
private final class GatedReportsRepository: ReportsRepositoryProtocol {
    let netWorth: [String: Int]
    let gated: String
    let entered = TestLatch()
    let release = TestLatch()

    init(netWorth: [String: Int], gated: String) {
        self.netWorth = netWorth
        self.gated = gated
    }

    func cachedReportsDashboard(budgetID: String, range: ReportDateRange) -> ReportsDashboardSnapshot? { nil }

    func refreshReportsDashboard(budgetID: String, range: ReportDateRange) async throws -> ReportsDashboardSnapshot {
        let result = Self.snapshot(range: range, netWorth: netWorth[budgetID] ?? 0)
        if budgetID == gated {
            entered.trip()
            await release.wait()
        }
        return result
    }

    func reportExplorerSnapshot(budgetID: String, query: ReportExplorerQuery) async throws -> ReportExplorerSnapshot {
        throw CancellationError()
    }

    private static func snapshot(range: ReportDateRange, netWorth: Int) -> ReportsDashboardSnapshot {
        let points = [DailyComparisonPoint(day: 1, current: 1_000, comparison: 500)]
        return ReportsDashboardSnapshot(
            range: range,
            hasData: true,
            netWorth: NetWorthReport(
                points: [ReportValuePoint(dayID: "2026-07-16", value: netWorth)], balance: netWorth, change: 0
            ),
            cashFlow: CashFlowSummary(month: "2026-07", income: 0, expenses: 0, net: 0, uncategorized: 0),
            monthComparison: MonthComparisonReport(
                currentMonth: "2026-07", comparisonMonth: "2026-06", points: points, variance: 0
            ),
            budgetOverview: BudgetOverviewReport(
                month: "2026-07", actualPoints: [], budgetPoints: [],
                actualExpenses: 0, budgetedExpenses: 0, variance: 0
            ),
            threeMonthAverage: ThreeMonthAverageReport(
                month: "2026-07", points: points, currentExpenses: 0, averageExpenses: 0, variance: 0
            ),
            transactionCalendar: []
        )
    }
}
