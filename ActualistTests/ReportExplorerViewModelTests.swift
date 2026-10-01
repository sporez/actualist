import Foundation
import Testing
@testable import Actualist

@MainActor
@Suite("Report Explorer View Model")
struct ReportExplorerViewModelTests {
    @Test func initialLoadPublishesLocalSnapshotAndFormatsTheSelectedCurrency() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let repository = ControlledExplorerRepository(plans: [
            "budget": [.success(total: 12_345)],
        ])

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

    @Test func totalsPresentationKeepsPrimaryAndSecondaryLabelsAndTonesConsistentAcrossMetrics() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let expectations: [(card: ReportCardKind, primary: String, secondary: [(label: String, tone: ReportValueTone)])] = [
            (.netWorth, "Ending balance", [("Change", .positive)]),
            (.cashFlow, "Net cash flow", [("Income", .positive), ("Expenses", .danger)]),
            (.monthComparison, "Total spending", []),
            (.budgetOverview, "Spending", [("Budgeted", .neutral)]),
            (.threeMonthAverage, "3-month average spending", [("This range", .danger)]),
        ]

        for expectation in expectations {
            let model = ReportExplorerViewModel(reportCard: expectation.card, now: now)
            let repository = ControlledExplorerRepository(plans: [
                "budget": [.success(total: 4_000)],
            ])
            await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)

            #expect(model.loadState == .loaded)
            #expect(model.primaryTotalLabel == expectation.primary)
            #expect(model.secondaryTotals.map(\.label) == expectation.secondary.map(\.label))
            #expect(model.secondaryTotals.map(\.tone) == expectation.secondary.map(\.tone))
        }
    }

    @Test func invalidCustomRangeDoesNotCallTheRepository() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let repository = ControlledExplorerRepository()

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

    @Test func spendingAverageSelectsOneComparisonMonthAndIgnoresRangeIntents() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 15)
        let model = ReportExplorerViewModel(reportCard: .threeMonthAverage, now: now)
        let initialQuery = model.query

        #expect(model.usesComparisonMonthSelection)
        #expect(model.query.startDay == "2026-01-01")
        #expect(model.query.endDay == "2026-01-15")
        #expect(model.rangeSelectionTitle == ReportCalendar.monthTitle("2026-01"))

        model.selectPreset(.threeMonths, now: now)
        model.selectCustomRange(
            start: try reportDate(year: 2025, month: 11, day: 1),
            end: now
        )
        #expect(model.query == initialQuery)

        model.selectPreviousComparisonMonth(now: now)
        #expect(model.query.startDay == "2025-12-01")
        #expect(model.query.endDay == "2025-12-31")
        #expect(model.rangeSelectionTitle == ReportCalendar.monthTitle("2025-12"))

        model.selectNextComparisonMonth(now: now)
        #expect(model.query.startDay == "2026-01-01")
        #expect(model.query.endDay == "2026-01-15")
    }

    @Test func applyingFiltersCreatesTheNextImmutableQueryAndRequestsItOnce() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .budgetOverview, now: now)
        let repository = ControlledExplorerRepository(plans: [
            "budget": [.success(total: 10)],
        ])
        let filters = ReportExplorerFilters(
            accounts: .only(["checking"]),
            categories: .only(["groceries"]),
            includesOffBudget: true,
            includesHiddenCategories: false,
            includesUncategorized: false
        )

        model.applyFilters(filters)
        await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)

        #expect(model.query.filters == filters)
        #expect(model.activeFilterCount == 5)
        #expect(repository.requestedQueries == [model.query])
    }

    @Test func filterDraftDistinguishesAllSomeAndExplicitlyEmptySelections() {
        var draft = ReportExplorerFilterDraft(filters: .default)
        let accountIDs: Set<String> = ["checking", "savings"]

        draft.setAccount("checking", selected: false, availableIDs: accountIDs)
        #expect(draft.filters.accounts == .only(["savings"]))
        draft.setAccount("checking", selected: true, availableIDs: accountIDs)
        #expect(draft.filters.accounts == .all)

        draft.clearAccounts()
        draft.clearCategories()
        #expect(draft.filters.accounts == .only([]))
        #expect(draft.filters.categories == .only([]))
        #expect(!draft.filters.includesUncategorized)
    }

    @Test func netWorthNormalizesUnsupportedCategoryVisibilityFilters() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .netWorth, now: now)
        model.applyFilters(ReportExplorerFilters(
            accounts: .only(["checking"]),
            categories: .only(["groceries"]),
            includesOffBudget: true,
            includesHiddenCategories: false,
            includesUncategorized: false
        ))

        #expect(model.query.filters.accounts == .only(["checking"]))
        #expect(model.query.filters.categories == .all)
        #expect(model.query.filters.includesOffBudget)
        #expect(model.query.filters.includesHiddenCategories)
        #expect(model.query.filters.includesUncategorized)
        #expect(model.query.validationError == nil)
    }

    @Test func privacyModeMasksFilterCatalogWithoutChangingQueryIdentity() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let source = makeSnapshot(
            query: model.query,
            total: 10,
            catalog: ReportExplorerFilterCatalog(
                accounts: [ReportExplorerAccountFilterOption(
                    id: "checking", name: "Private Checking", isOffBudget: false, isClosed: false
                )],
                categories: [ReportExplorerCategoryFilterOption(
                    id: "groceries", name: "Private Groceries", groupID: "needs",
                    groupName: "Private Needs", isIncome: false, isHidden: false
                )]
            )
        )
        let repository = ControlledExplorerRepository(plans: ["budget": [.snapshot(source)]])

        await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: true)

        #expect(model.snapshot?.filterCatalog.accounts.first?.name == "Private Checking")
        #expect(model.displaySnapshot?.filterCatalog.accounts.first?.name != "Private Checking")
        #expect(model.displaySnapshot?.filterCatalog.categories.first?.name != "Private Groceries")
        #expect(model.displaySnapshot?.query == source.query)
    }

    @Test func budgetSwitchClearsOldSnapshotWhileNewBudgetIsPendingThenPublishesNewResult() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let started = TestLatch()
        let release = TestLatch()
        let repository = ControlledExplorerRepository(plans: [
            "A": [.success(total: 10)],
            "B": [.suspendedSuccess(total: 20, started: started, release: release)],
        ])

        await model.load(budgetID: "A", repository: repository, privacyModeEnabled: false)
        let budgetBLoad = Task {
            await model.load(budgetID: "B", repository: repository, privacyModeEnabled: false)
        }
        await started.wait()

        #expect(model.snapshot == nil)
        #expect(model.displaySnapshot == nil)
        #expect(model.loadState == .loading)

        release.trip()
        await budgetBLoad.value
        #expect(model.displaySnapshot?.totals.net == 20)
        #expect(model.loadState == .loaded)
    }

    @Test func budgetSwitchFailureNeverRestoresThePreviousBudgetSnapshot() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let repository = ControlledExplorerRepository(plans: [
            "A": [.success(total: 10)],
            "B": [.failure],
        ])

        await model.load(budgetID: "A", repository: repository, privacyModeEnabled: false)
        await model.load(budgetID: "B", repository: repository, privacyModeEnabled: false)

        #expect(model.snapshot == nil)
        #expect(model.displaySnapshot == nil)
        #expect(model.errorMessage != nil)
    }

    @Test func sameBudgetNewSessionClearsThePreviousSessionSnapshot() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let started = TestLatch()
        let release = TestLatch()
        let repository = ControlledExplorerRepository(plans: [
            "budget": [
                .success(total: 10),
                .suspendedSuccess(total: 20, started: started, release: release),
            ],
        ])

        await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)
        repository.sessionGenerationByBudget["budget"] = 1
        let replacementLoad = Task {
            await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)
        }
        await started.wait()

        #expect(model.displaySnapshot == nil)
        #expect(model.loadState == .loading)

        release.trip()
        await replacementLoad.value
        #expect(model.displaySnapshot?.totals.net == 20)
    }

    @Test func cancellationInsensitiveLateBudgetSuccessCannotReplaceNewSession() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let started = TestLatch()
        let release = TestLatch()
        let repository = ControlledExplorerRepository(plans: [
            "A": [.suspendedSuccess(total: 10, started: started, release: release)],
            "B": [.success(total: 20)],
        ])

        let oldLoad = Task {
            await model.load(budgetID: "A", repository: repository, privacyModeEnabled: false)
        }
        await started.wait()
        oldLoad.cancel()

        await model.load(budgetID: "B", repository: repository, privacyModeEnabled: false)
        release.trip()
        await oldLoad.value

        #expect(model.displaySnapshot?.totals.net == 20)
        #expect(model.loadState == .loaded)
    }

    @Test func staleCompletionCannotReplaceANewerRange() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let started = TestLatch()
        let release = TestLatch()
        let repository = ControlledExplorerRepository(plans: [
            "budget": [
                .suspendedSuccess(total: 1, started: started, release: release),
                .success(total: 2),
            ],
        ])

        let firstLoad = Task {
            await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)
        }
        await started.wait()

        model.selectPreset(.threeMonths, now: now)
        await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)
        release.trip()
        await firstLoad.value

        #expect(model.query.startDay == "2025-11-01")
        #expect(model.displaySnapshot?.query == model.query)
        #expect(model.displaySnapshot?.totals.net == 2)
        #expect(model.loadState == .loaded)
    }

    @Test func sameSessionRefreshFailureRetainsSnapshotAndRetryCanRecover() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .cashFlow, now: now)
        let repository = ControlledExplorerRepository(plans: [
            "budget": [.success(total: 10), .failure, .success(total: 30)],
        ])

        await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)
        model.reload()
        await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)

        #expect(model.displaySnapshot?.totals.net == 10)
        #expect(model.errorMessage != nil)

        let failedRequestIdentity = model.requestIdentity
        model.retry()
        #expect(model.requestIdentity != failedRequestIdentity)
        await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)

        #expect(model.displaySnapshot?.totals.net == 30)
        #expect(model.loadState == .loaded)
    }

    @Test func privacyChangesDuringLoadUseCurrentModeAndOnePeriodNetWorthKeepsOpeningChange() async throws {
        let now = try reportDate(year: 2026, month: 1, day: 31)
        let model = ReportExplorerViewModel(reportCard: .netWorth, now: now)
        let started = TestLatch()
        let release = TestLatch()
        let repository = ControlledExplorerRepository(plans: [
            "budget": [
                .suspendedSnapshot(
                    makeNetWorthSnapshot(query: model.query, opening: 100_000, ending: 123_456),
                    started: started,
                    release: release
                ),
            ],
        ])

        let load = Task {
            await model.load(budgetID: "budget", repository: repository, privacyModeEnabled: false)
        }
        await started.wait()
        model.updatePrivacyMode(true)
        release.trip()
        await load.value

        let privateSnapshot = try #require(model.displaySnapshot)
        #expect(privateSnapshot.totals.openingBalance != 100_000)
        #expect(privateSnapshot.totals.balanceChange != 0)
        #expect(privateSnapshot.totals.endingBalance
            == privateSnapshot.totals.openingBalance + privateSnapshot.totals.balanceChange)

        model.updatePrivacyMode(false)
        #expect(model.displaySnapshot?.totals.openingBalance == 100_000)
        #expect(model.displaySnapshot?.totals.balanceChange == 23_456)
        #expect(model.displaySnapshot?.totals.endingBalance == 123_456)
    }

    private func reportDate(year: Int, month: Int, day: Int) throws -> Date {
        try #require(ReportCalendar.gregorianLocal.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        ))
    }
}

@MainActor
private final class ControlledExplorerRepository: ReportsRepositoryProtocol {
    enum Plan {
        case success(total: Int)
        case suspendedSuccess(total: Int, started: TestLatch, release: TestLatch)
        case suspendedSnapshot(ReportExplorerSnapshot, started: TestLatch, release: TestLatch)
        case snapshot(ReportExplorerSnapshot)
        case failure
    }

    var plans: [String: [Plan]]
    var sessionGenerationByBudget: [String: Int] = [:]
    var requestedQueries: [ReportExplorerQuery] = []

    init(plans: [String: [Plan]] = [:]) {
        self.plans = plans
    }

    func reportExplorerSessionIdentity(budgetID: String) -> ReportExplorerSessionIdentity {
        ReportExplorerSessionIdentity(
            budgetID: budgetID,
            generation: sessionGenerationByBudget[budgetID] ?? 0
        )
    }

    func cachedReportsDashboard(budgetID: String, range: ReportDateRange) -> ReportsDashboardSnapshot? { nil }

    func refreshReportsDashboard(
        budgetID: String,
        range: ReportDateRange
    ) async throws -> ReportsDashboardSnapshot {
        throw ExplorerTestError.failed
    }

    func reportExplorerSnapshot(
        budgetID: String,
        query: ReportExplorerQuery
    ) async throws -> ReportExplorerSnapshot {
        requestedQueries.append(query)
        guard var budgetPlans = plans[budgetID], !budgetPlans.isEmpty else {
            throw ExplorerTestError.failed
        }
        let plan = budgetPlans.removeFirst()
        plans[budgetID] = budgetPlans
        switch plan {
        case .success(let total):
            return makeSnapshot(query: query, total: total)
        case .suspendedSuccess(let total, let started, let release):
            started.trip()
            await release.wait()
            return makeSnapshot(query: query, total: total)
        case .suspendedSnapshot(let snapshot, let started, let release):
            started.trip()
            await release.wait()
            return snapshot
        case .snapshot(let snapshot):
            return snapshot
        case .failure:
            throw ExplorerTestError.failed
        }
    }
}

private enum ExplorerTestError: Error {
    case failed
}

private func makeSnapshot(
    query: ReportExplorerQuery,
    total: Int,
    catalog: ReportExplorerFilterCatalog = .empty
) -> ReportExplorerSnapshot {
    let period = query.periods.first
        ?? ReportExplorerPeriod(startDay: query.startDay, endDay: query.endDay)
    let point = ReportExplorerPoint(
        period: period,
        income: total,
        expenses: 0,
        net: total,
        endingBalance: total,
        budgeted: 0,
        comparison: 0
    )
    return ReportExplorerSnapshot(
        query: query,
        points: [point],
        totals: ReportExplorerTotals(
            income: total,
            expenses: 0,
            net: total,
            endingBalance: total,
            balanceChange: total,
            openingBalance: 0,
            budgeted: 0,
            averageSpending: 0
        ),
        hasData: true,
        filterCatalog: catalog
    )
}

private func makeNetWorthSnapshot(
    query: ReportExplorerQuery,
    opening: Int,
    ending: Int
) -> ReportExplorerSnapshot {
    let period = query.periods.first
        ?? ReportExplorerPeriod(startDay: query.startDay, endDay: query.endDay)
    return ReportExplorerSnapshot(
        query: query,
        points: [ReportExplorerPoint(
            period: period,
            income: 0,
            expenses: 0,
            net: 0,
            endingBalance: ending,
            budgeted: 0,
            comparison: 0
        )],
        totals: ReportExplorerTotals(
            income: 0,
            expenses: 0,
            net: 0,
            endingBalance: ending,
            balanceChange: ending - opening,
            openingBalance: opening,
            budgeted: 0,
            averageSpending: 0
        ),
        hasData: true
    )
}
