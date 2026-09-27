import Foundation
import Testing
@testable import Actualist

@MainActor
@Suite("Report Explorer View Model")
struct ReportExplorerViewModelTests {
    @Test func initialLoadPublishesLocalSnapshotAndFormatsTheSelectedCurrency() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let repository = ImmediateExplorerRepository(total: 12_345)

        await model.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: false,
            currency: .usd
        )

        #expect(model.loadState == .loaded)
        #expect(model.displaySnapshot?.query == model.query)
        #expect(model.primaryTotalText.contains("123.45"))
        #expect(repository.requestedQueries == [model.query])
    }

    @Test func invalidCustomRangeDoesNotCallTheRepository() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let repository = ImmediateExplorerRepository(total: 1)

        model.selectCustomRange(
            start: try reportDate(year: 2026, month: 2, day: 1),
            end: try reportDate(year: 2026, month: 1, day: 1)
        )
        await model.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: false
        )

        #expect(model.loadState == .invalidRange)
        #expect(model.invalidRangeMessage != nil)
        #expect(repository.requestedQueries.isEmpty)
    }

    @Test func staleCompletionCannotReplaceANewerRange() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let repository = SuspendedExplorerRepository()

        let firstLoad = Task {
            await model.load(
                budgetID: "budget",
                repository: repository,
                privacyModeEnabled: false
            )
        }
        await repository.firstRequestStarted.wait()

        model.selectPreset(.threeMonths, now: now)
        await model.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: false
        )
        repository.releaseFirstRequest.trip()
        await firstLoad.value

        #expect(model.query.startDay == "2025-11-01")
        #expect(model.displaySnapshot?.query == model.query)
        #expect(model.displaySnapshot?.totals.net == 2)
        #expect(model.loadState == .loaded)
    }

    @Test func privacyModeReprojectsLoadedDetailAmounts() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .netWorth, now: now)
        let repository = ImmediateExplorerRepository(total: 123_456)

        await model.load(
            budgetID: "budget",
            repository: repository,
            privacyModeEnabled: false
        )
        let raw = try #require(model.displaySnapshot)
        model.updatePrivacyMode(true)

        #expect(model.displaySnapshot != raw)
        #expect(model.displaySnapshot?.totals.endingBalance != raw.totals.endingBalance)
    }

    private func reportDate(year: Int, month: Int, day: Int) throws -> Date {
        try #require(ReportCalendar.gregorianLocal.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        ))
    }
}

@MainActor
private final class ImmediateExplorerRepository: ReportsRepositoryProtocol {
    let total: Int
    var requestedQueries: [ReportExplorerQuery] = []

    init(total: Int) {
        self.total = total
    }

    func cachedReportsDashboard(budgetID: String, range: ReportDateRange) -> ReportsDashboardSnapshot? { nil }

    func refreshReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) async throws -> ReportsDashboardSnapshot {
        throw ReportExplorerError.invalidRange
    }

    func reportExplorerSnapshot(
        budgetID: String,
        query: ReportExplorerQuery
    ) async throws -> ReportExplorerSnapshot {
        requestedQueries.append(query)
        return makeSnapshot(query: query, total: total)
    }
}

@MainActor
private final class SuspendedExplorerRepository: ReportsRepositoryProtocol {
    let firstRequestStarted = TestLatch()
    let releaseFirstRequest = TestLatch()
    private var requestCount = 0

    func cachedReportsDashboard(budgetID: String, range: ReportDateRange) -> ReportsDashboardSnapshot? { nil }

    func refreshReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) async throws -> ReportsDashboardSnapshot {
        throw ReportExplorerError.invalidRange
    }

    func reportExplorerSnapshot(
        budgetID: String,
        query: ReportExplorerQuery
    ) async throws -> ReportExplorerSnapshot {
        requestCount += 1
        let request = requestCount
        if request == 1 {
            firstRequestStarted.trip()
            await releaseFirstRequest.wait()
        }
        return makeSnapshot(query: query, total: request)
    }
}

private func makeSnapshot(query: ReportExplorerQuery, total: Int) -> ReportExplorerSnapshot {
    let period = query.periods.first
        ?? ReportExplorerPeriod(startDay: query.startDay, endDay: query.endDay)
    let point = ReportExplorerPoint(
        period: period,
        income: total,
        expenses: 0,
        net: total,
        endingBalance: total
    )
    return ReportExplorerSnapshot(
        query: query,
        points: [point],
        totals: ReportExplorerTotals(
            income: total,
            expenses: 0,
            net: total,
            endingBalance: total,
            balanceChange: total
        ),
        hasData: true
    )
}
