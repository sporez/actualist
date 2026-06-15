import Foundation
import Observation

@MainActor
@Observable
final class BudgetViewModel {
    var budgetMonth: BudgetMonth?
    var selectedMonth: String?
    var availableMonths: [String] = []
    var budgetAlerts: [BudgetAlert] = []
    var expandedGroupIDs: Set<String> = []
    var isLoading = false
    var errorMessage: String?

    var navigationTitle: String {
        guard let selectedMonth else {
            return Self.title(for: Date())
        }

        return Self.title(forMonthIdentifier: selectedMonth)
    }

    var visibleGroups: [BudgetMonthCategoryGroup] {
        budgetMonth?.categoryGroups.filter { !$0.isIncome } ?? []
    }

    var overspendingAlertCount: Int? {
        guard let budgetMonth else {
            return nil
        }

        let overspentCategoryCount = visibleGroups
            .flatMap(\.visibleCategories)
            .filter { $0.balance < 0 }
            .count

        if overspentCategoryCount > 0 {
            return overspentCategoryCount
        }

        return budgetMonth.lastMonthOverspent < 0 ? 1 : nil
    }

    var preferredMonth: String {
        YearMonth(date: Date()).rawValue
    }

    func load(using appState: AppState) async {
        await appState.loadBudgets()

        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return
        }

        await load(budgetID: budgetID, repository: repository)
    }

    func load(
        budgetID: String,
        repository: BudgetRepository
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            let loadedMonth = try await repository.currentBudgetMonth(
                budgetID: budgetID,
                preferredMonth: preferredMonth
            )
            apply(loadedMonth)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func selectMonth(_ month: String, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID,
              let repository = appState.makeBudgetRepository() else {
            return
        }

        await selectMonth(month, budgetID: budgetID, repository: repository)
    }

    func refreshSelectedMonth(using appState: AppState) async {
        guard let selectedMonth else {
            await load(using: appState)
            return
        }

        await selectMonth(selectedMonth, using: appState)
    }

    func selectMonth(
        _ month: String,
        budgetID: String,
        repository: BudgetRepository
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            let loadedMonth = try await repository.budgetMonth(
                budgetID: budgetID,
                selectedMonth: month
            )
            apply(loadedMonth)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func isExpanded(_ group: BudgetMonthCategoryGroup) -> Bool {
        expandedGroupIDs.contains(group.id)
    }

    func toggle(_ group: BudgetMonthCategoryGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }

    private static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private static func title(forMonthIdentifier month: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM"
        guard let date = input.date(from: month) else {
            return month
        }

        return title(for: date)
    }

    private func apply(_ loadedMonth: LoadedBudgetMonth) {
        availableMonths = loadedMonth.availableMonths
        budgetMonth = loadedMonth.month
        selectedMonth = loadedMonth.month.month
        budgetAlerts = loadedMonth.alerts.compactMap(BudgetAlert.init(apiAlert:))
        expandedGroupIDs = Set(loadedMonth.month.categoryGroups.prefix(3).map(\.id))
    }
}

struct BudgetAlert: Identifiable, Equatable {
    enum Kind: String {
        case toBudget
        case overspending
        case uncategorizedTransactions
    }

    enum Severity: Equatable {
        case positive
        case warning
        case danger
    }

    let kind: Kind
    let title: String
    let valueText: String?
    let count: Int?
    let actionTitle: String?
    let severity: Severity

    var id: String {
        kind.rawValue
    }

    init(
        kind: Kind,
        title: String,
        valueText: String? = nil,
        count: Int? = nil,
        actionTitle: String?,
        severity: Severity
    ) {
        self.kind = kind
        self.title = title
        self.valueText = valueText
        self.count = count
        self.actionTitle = actionTitle
        self.severity = severity
    }

    init?(apiAlert: APIBudgetMonthAlert) {
        guard let kind = Kind(rawValue: apiAlert.kind) else {
            return nil
        }

        self.kind = kind
        title = apiAlert.title
        valueText = apiAlert.amount?.actualMoney.formatted()
        count = apiAlert.count
        actionTitle = apiAlert.actionTitle
        severity = Severity(apiValue: apiAlert.severity)
    }
}

private extension BudgetAlert.Severity {
    init(apiValue: String) {
        switch apiValue {
        case "positive":
            self = .positive
        case "danger":
            self = .danger
        default:
            self = .warning
        }
    }
}

extension BudgetMonthCategoryGroup {
    var visibleCategories: [BudgetMonthCategory] {
        categories.filter { !($0.hidden ?? false) }
    }
}
