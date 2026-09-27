import Foundation
import Observation

@MainActor
@Observable
final class ReportExplorerViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case refreshing
        case loaded
        case invalidRange
        case failed(String)
    }

    let reportCard: ReportCardKind
    private(set) var query: ReportExplorerQuery
    private(set) var selectedPreset: ReportExplorerRangePreset
    private(set) var snapshot: ReportExplorerSnapshot?
    private(set) var displaySnapshot: ReportExplorerSnapshot?
    private(set) var loadState: LoadState = .idle
    private(set) var requestIdentity = UUID()
    private(set) var currency: BudgetCurrency = .usd
    private(set) var isPrivacyModeEnabled = false
    private var requestGeneration = 0
    private var activeSessionIdentity: ReportExplorerSessionIdentity?

    init(reportCard: ReportCardKind, now: Date = Date()) {
        self.reportCard = reportCard
        selectedPreset = reportCard.explorerDefaultPreset
        let range = reportCard.explorerDefaultPreset.range(through: now)
            ?? ReportExplorerRangePreset.monthToDate.range(through: now)
            ?? (startDay: "1970-01-01", endDay: "1970-01-01")
        query = ReportExplorerQuery(
            metric: reportCard.explorerMetric,
            startDay: range.startDay,
            endDay: range.endDay,
            interval: reportCard.explorerDefaultInterval
        )
    }

    var title: String { reportCard.title }
    var rangeTitle: String { query.rangeTitle }
    var usesComparisonMonthSelection: Bool { query.metric == .spendingAverage }
    var rangeSelectionTitle: String {
        usesComparisonMonthSelection
            ? ReportCalendar.monthTitle(String(query.startDay.prefix(7)))
            : selectedPreset.title
    }
    var canSelectNextComparisonMonth: Bool {
        canAdvanceComparisonMonth(through: Date())
    }
    var isLoading: Bool { loadState == .loading }
    var isRefreshing: Bool { loadState == .refreshing }
    var invalidRangeMessage: String? {
        guard loadState == .invalidRange else { return nil }
        return query.validationError?.errorDescription
    }
    var errorMessage: String? {
        guard case .failed(let message) = loadState else { return nil }
        return message
    }
    var customStartDate: Date {
        ReportCalendar.date(fromDayID: query.startDay) ?? .distantPast
    }
    var customEndDate: Date {
        ReportCalendar.date(fromDayID: query.endDay) ?? .distantPast
    }
    var filterCatalog: ReportExplorerFilterCatalog {
        displaySnapshot?.filterCatalog ?? snapshot?.filterCatalog ?? .empty
    }
    var filters: ReportExplorerFilters { query.filters }
    var drilldownRequest: TransactionDrilldownRequest? {
        guard let drilldown = snapshot?.drilldown,
              case .transactions(let request) = drilldown else { return nil }
        return request
    }
    var activeFilterCount: Int {
        var count = 0
        if !query.filters.accounts.isAll { count += 1 }
        if query.metric.supportsCategoryFilters, !query.filters.categories.isAll { count += 1 }
        if query.filters.includesOffBudget { count += 1 }
        if query.metric.supportsActivityVisibility, !query.filters.includesHiddenCategories { count += 1 }
        if query.metric.supportsActivityVisibility, !query.filters.includesUncategorized { count += 1 }
        return count
    }

    func selectPreset(_ preset: ReportExplorerRangePreset, now: Date = Date()) {
        guard !usesComparisonMonthSelection else { return }
        guard let range = preset.range(through: now) else { return }
        selectedPreset = preset
        updateQuery(startDay: range.startDay, endDay: range.endDay, interval: query.interval)
    }

    func selectCustomRange(start: Date, end: Date) {
        guard !usesComparisonMonthSelection else { return }
        selectedPreset = .custom
        updateQuery(
            startDay: ReportCalendar.dayID(for: start),
            endDay: ReportCalendar.dayID(for: end),
            interval: query.interval
        )
    }

    func selectInterval(_ interval: ReportInterval) {
        updateQuery(startDay: query.startDay, endDay: query.endDay, interval: interval)
    }

    func selectPreviousComparisonMonth(now: Date = Date()) {
        guard usesComparisonMonthSelection else { return }
        selectComparisonMonth(
            ReportCalendar.shiftedMonth(String(query.startDay.prefix(7)), by: -1),
            now: now
        )
    }

    func selectNextComparisonMonth(now: Date = Date()) {
        guard canAdvanceComparisonMonth(through: now) else { return }
        selectComparisonMonth(
            ReportCalendar.shiftedMonth(String(query.startDay.prefix(7)), by: 1),
            now: now
        )
    }

    func reload() {
        requestGeneration &+= 1
        requestIdentity = UUID()
    }

    func retry() {
        reload()
    }

    func updatePrivacyMode(_ isEnabled: Bool) {
        guard isPrivacyModeEnabled != isEnabled else { return }
        isPrivacyModeEnabled = isEnabled
        displaySnapshot = snapshot.map(sanitized)
    }

    func applyFilters(_ filters: ReportExplorerFilters) {
        var normalized = filters
        if query.metric == .netWorth {
            normalized.categories = .all
            normalized.includesHiddenCategories = true
            normalized.includesUncategorized = true
        }
        updateQuery(
            startDay: query.startDay,
            endDay: query.endDay,
            interval: query.interval,
            filters: normalized
        )
    }

    func load(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            bind(to: nil)
            loadState = .failed("Open a budget before loading this report.")
            return
        }
        await load(
            budgetID: budgetID,
            repository: appState.reportsRepository,
            privacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
            currency: appState.localFirstStore.budgetCurrency(budgetID: budgetID)
        )
    }

    func load(
        budgetID: String,
        repository: any ReportsRepositoryProtocol,
        privacyModeEnabled: Bool,
        currency: BudgetCurrency = .usd
    ) async {
        let sessionIdentity = repository.reportExplorerSessionIdentity(budgetID: budgetID)
        bind(to: sessionIdentity)
        guard query.hasValidRange else {
            loadState = .invalidRange
            return
        }

        requestGeneration &+= 1
        let generation = requestGeneration
        let requestedQuery = query
        let requestedSessionIdentity = sessionIdentity
        self.currency = currency
        isPrivacyModeEnabled = privacyModeEnabled
        loadState = snapshot?.query == requestedQuery ? .refreshing : .loading

        do {
            let loaded = try await repository.reportExplorerSnapshot(
                budgetID: budgetID,
                query: requestedQuery
            )
            guard requestGeneration == generation,
                  query == requestedQuery,
                  activeSessionIdentity == requestedSessionIdentity,
                  repository.reportExplorerSessionIdentity(budgetID: budgetID) == requestedSessionIdentity,
                  !Task.isCancelled else {
                return
            }
            snapshot = loaded
            displaySnapshot = sanitized(loaded)
            loadState = .loaded
        } catch {
            guard requestGeneration == generation,
                  query == requestedQuery,
                  activeSessionIdentity == requestedSessionIdentity,
                  repository.reportExplorerSessionIdentity(budgetID: budgetID) == requestedSessionIdentity else {
                return
            }
            if error.isCancellation || Task.isCancelled {
                loadState = snapshot == nil ? .idle : .loaded
            } else {
                loadState = .failed(error.userFacingMessage ?? "This report could not be loaded.")
            }
        }
    }

    var primaryTotalText: String {
        guard let totals = displaySnapshot?.totals else { return currency.formatted(0) }
        switch query.metric {
        case .netWorth:
            return currency.formatted(totals.endingBalance)
        case .cashFlow:
            return signedMoney(totals.net)
        case .spending, .budgetOverview:
            return currency.formatted(totals.expenses)
        case .spendingAverage:
            return currency.formatted(totals.averageSpending)
        }
    }

    var primaryTotalLabel: String {
        switch query.metric {
        case .netWorth: "Ending balance"
        case .cashFlow: "Net cash flow"
        case .spending: "Total spending"
        case .budgetOverview: "Spending"
        case .spendingAverage: "3-month average spending"
        }
    }

    var secondaryTotals: [(label: String, value: String, tone: ReportValueTone)] {
        guard let totals = displaySnapshot?.totals else { return [] }
        switch query.metric {
        case .netWorth:
            return [("Change", signedMoney(totals.balanceChange), comparisonTone(totals.balanceChange))]
        case .cashFlow:
            return [
                ("Income", currency.formatted(totals.income), .positive),
                ("Expenses", currency.formatted(totals.expenses), .danger),
            ]
        case .spending:
            return []
        case .budgetOverview:
            return [("Budgeted", currency.formatted(totals.budgeted), .neutral)]
        case .spendingAverage:
            return [("This range", currency.formatted(totals.expenses), .danger)]
        }
    }

    func formatted(_ amount: Int) -> String {
        currency.formatted(amount)
    }

    private func updateQuery(
        startDay: String,
        endDay: String,
        interval: ReportInterval,
        filters: ReportExplorerFilters? = nil
    ) {
        let updated = ReportExplorerQuery(
            metric: query.metric,
            startDay: startDay,
            endDay: endDay,
            interval: interval,
            filters: filters ?? query.filters
        )
        guard updated != query else { return }
        requestGeneration &+= 1
        query = updated
        snapshot = nil
        displaySnapshot = nil
        loadState = updated.hasValidRange ? .idle : .invalidRange
        requestIdentity = UUID()
    }

    private func selectComparisonMonth(_ month: String, now: Date) {
        let currentMonth = ReportCalendar.monthID(for: now, calendar: ReportCalendar.gregorianLocal)
        guard month <= currentMonth else { return }
        let endDay = month == currentMonth
            ? ReportCalendar.dayID(for: now, calendar: ReportCalendar.gregorianLocal)
            : ReportCalendar.dayID(month: month, day: max(ReportCalendar.days(in: month), 1))
        updateQuery(
            startDay: ReportCalendar.dayID(month: month, day: 1),
            endDay: endDay,
            interval: query.interval
        )
    }

    private func canAdvanceComparisonMonth(through date: Date) -> Bool {
        guard usesComparisonMonthSelection else { return false }
        let currentMonth = ReportCalendar.monthID(for: date, calendar: ReportCalendar.gregorianLocal)
        return String(query.startDay.prefix(7)) < currentMonth
    }

    private func sanitized(_ snapshot: ReportExplorerSnapshot) -> ReportExplorerSnapshot {
        guard isPrivacyModeEnabled else { return snapshot }
        if snapshot.query.metric == .netWorth {
            return sanitizedNetWorth(snapshot)
        }

        let points = snapshot.points.map { point in
            let income = masked(point.income, seed: "report-detail-income-\(point.period.id)")
            let expenses = masked(point.expenses, seed: "report-detail-expenses-\(point.period.id)")
            return ReportExplorerPoint(
                period: point.period,
                income: income,
                expenses: expenses,
                net: income - expenses,
                endingBalance: 0,
                budgeted: masked(point.budgeted, seed: "report-detail-budgeted-\(point.period.id)"),
                comparison: masked(point.comparison, seed: "report-detail-comparison-\(point.period.id)")
            )
        }
        let income = points.reduce(0) { $0 + $1.income }
        let expenses: Int
        let budgeted: Int
        switch snapshot.query.metric {
        case .budgetOverview, .spendingAverage:
            expenses = points.last?.expenses ?? 0
            budgeted = points.last?.budgeted ?? 0
        default:
            expenses = points.reduce(0) { $0 + $1.expenses }
            budgeted = points.reduce(0) { $0 + $1.budgeted }
        }
        return ReportExplorerSnapshot(
            query: snapshot.query,
            points: points,
            totals: ReportExplorerTotals(
                income: income,
                expenses: expenses,
                net: income - expenses,
                endingBalance: 0,
                balanceChange: 0,
                openingBalance: 0,
                budgeted: budgeted,
                averageSpending: snapshot.query.metric == .spendingAverage
                    ? points.last?.comparison ?? 0
                    : 0
            ),
            hasData: snapshot.hasData,
            filterCatalog: sanitized(snapshot.filterCatalog),
            drilldown: snapshot.drilldown,
            activityQuerySignature: snapshot.activityQuerySignature,
            historyQuerySignature: snapshot.historyQuerySignature
        )
    }

    private func sanitizedNetWorth(_ snapshot: ReportExplorerSnapshot) -> ReportExplorerSnapshot {
        let openingBalance = masked(
            snapshot.totals.openingBalance,
            seed: "report-detail-opening-balance"
        )
        let balanceChange = masked(
            snapshot.totals.balanceChange,
            seed: "report-detail-balance-change"
        )
        let endingBalance = openingBalance + balanceChange
        let points = snapshot.points.enumerated().map { index, point in
            ReportExplorerPoint(
                period: point.period,
                income: 0,
                expenses: 0,
                net: 0,
                endingBalance: index == snapshot.points.count - 1
                    ? endingBalance
                    : masked(point.endingBalance, seed: "report-detail-balance-\(point.period.id)"),
                budgeted: 0,
                comparison: 0
            )
        }
        return ReportExplorerSnapshot(
            query: snapshot.query,
            points: points,
            totals: ReportExplorerTotals(
                income: 0,
                expenses: 0,
                net: 0,
                endingBalance: endingBalance,
                balanceChange: balanceChange,
                openingBalance: openingBalance,
                budgeted: 0,
                averageSpending: 0
            ),
            hasData: snapshot.hasData,
            filterCatalog: sanitized(snapshot.filterCatalog),
            drilldown: snapshot.drilldown,
            activityQuerySignature: snapshot.activityQuerySignature,
            historyQuerySignature: snapshot.historyQuerySignature
        )
    }

    private func sanitized(_ catalog: ReportExplorerFilterCatalog) -> ReportExplorerFilterCatalog {
        ReportExplorerFilterCatalog(
            accounts: catalog.accounts.map { option in
                ReportExplorerAccountFilterOption(
                    id: option.id,
                    name: PrivacyDisplay.name(for: .account, seed: option.id),
                    isOffBudget: option.isOffBudget,
                    isClosed: option.isClosed
                )
            },
            categories: catalog.categories.map { option in
                ReportExplorerCategoryFilterOption(
                    id: option.id,
                    name: PrivacyDisplay.name(for: .category, seed: option.id),
                    groupID: option.groupID,
                    groupName: option.groupID.map {
                        PrivacyDisplay.name(for: .categoryGroup, seed: $0)
                    } ?? "Categories",
                    isIncome: option.isIncome,
                    isHidden: option.isHidden
                )
            }
        )
    }

    private func bind(to sessionIdentity: ReportExplorerSessionIdentity?) {
        guard activeSessionIdentity != sessionIdentity else { return }
        requestGeneration &+= 1
        activeSessionIdentity = sessionIdentity
        snapshot = nil
        displaySnapshot = nil
        loadState = .idle
    }

    private func masked(_ amount: Int, seed: String) -> Int {
        guard amount != 0 else { return 0 }
        return PrivacyDisplay.amount(
            amount,
            seed: seed,
            currency: currency,
            minimumDollars: 4,
            maximumDollars: 250_000
        )
    }

    private func signedMoney(_ amount: Int) -> String {
        amount > 0 ? "+\(currency.formatted(amount))" : currency.formatted(amount)
    }

    private func comparisonTone(_ amount: Int) -> ReportValueTone {
        if amount > 0 { return .positive }
        if amount < 0 { return .danger }
        return .neutral
    }
}
