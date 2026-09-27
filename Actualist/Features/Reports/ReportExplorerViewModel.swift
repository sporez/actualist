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
            interval: .month
        )
    }

    var title: String { reportCard.title }
    var rangeTitle: String { query.rangeTitle }
    var isLoading: Bool { loadState == .loading }
    var isRefreshing: Bool { loadState == .refreshing }
    var invalidRangeMessage: String? {
        guard loadState == .invalidRange else { return nil }
        return ReportExplorerError.invalidRange.errorDescription
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

    func selectPreset(_ preset: ReportExplorerRangePreset, now: Date = Date()) {
        guard let range = preset.range(through: now) else { return }
        selectedPreset = preset
        updateQuery(startDay: range.startDay, endDay: range.endDay, interval: query.interval)
    }

    func selectCustomRange(start: Date, end: Date) {
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

    func reload() {
        requestGeneration &+= 1
        requestIdentity = UUID()
    }

    func updatePrivacyMode(_ isEnabled: Bool) {
        guard isPrivacyModeEnabled != isEnabled else { return }
        isPrivacyModeEnabled = isEnabled
        displaySnapshot = snapshot.map(sanitized)
    }

    func load(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
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
        guard query.hasValidRange else {
            loadState = .invalidRange
            return
        }

        requestGeneration &+= 1
        let generation = requestGeneration
        let requestedQuery = query
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
                  !Task.isCancelled else {
                return
            }
            snapshot = loaded
            displaySnapshot = sanitized(loaded)
            loadState = .loaded
        } catch {
            guard requestGeneration == generation, query == requestedQuery else { return }
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
        case .spending:
            return currency.formatted(totals.expenses)
        }
    }

    var primaryTotalLabel: String {
        switch query.metric {
        case .netWorth: "Ending balance"
        case .cashFlow: "Net cash flow"
        case .spending: "Total spending"
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
        }
    }

    func formatted(_ amount: Int) -> String {
        currency.formatted(amount)
    }

    private func updateQuery(startDay: String, endDay: String, interval: ReportInterval) {
        let updated = ReportExplorerQuery(
            metric: query.metric,
            startDay: startDay,
            endDay: endDay,
            interval: interval
        )
        guard updated != query else { return }
        requestGeneration &+= 1
        query = updated
        snapshot = nil
        displaySnapshot = nil
        loadState = updated.hasValidRange ? .idle : .invalidRange
        requestIdentity = UUID()
    }

    private func sanitized(_ snapshot: ReportExplorerSnapshot) -> ReportExplorerSnapshot {
        guard isPrivacyModeEnabled else { return snapshot }
        let points = snapshot.points.map { point in
            ReportExplorerPoint(
                period: point.period,
                income: masked(point.income, seed: "report-detail-income-\(point.period.id)"),
                expenses: masked(point.expenses, seed: "report-detail-expenses-\(point.period.id)"),
                net: 0,
                endingBalance: masked(point.endingBalance, seed: "report-detail-balance-\(point.period.id)")
            )
        }.map { point in
            ReportExplorerPoint(
                period: point.period,
                income: point.income,
                expenses: point.expenses,
                net: point.income - point.expenses,
                endingBalance: point.endingBalance
            )
        }
        let income = points.reduce(0) { $0 + $1.income }
        let expenses = points.reduce(0) { $0 + $1.expenses }
        let endingBalance = points.last?.endingBalance ?? 0
        let firstBalance = points.first?.endingBalance ?? endingBalance
        return ReportExplorerSnapshot(
            query: snapshot.query,
            points: points,
            totals: ReportExplorerTotals(
                income: income,
                expenses: expenses,
                net: income - expenses,
                endingBalance: endingBalance,
                balanceChange: endingBalance - firstBalance
            ),
            hasData: snapshot.hasData
        )
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
