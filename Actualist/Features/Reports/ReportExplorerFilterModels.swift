import Foundation

enum ReportFilterSelection: Hashable, Sendable {
    case all
    case only(Set<String>)

    var isAll: Bool {
        if case .all = self { true } else { false }
    }
}

struct ReportExplorerFilters: Hashable, Sendable {
    var accounts: ReportFilterSelection
    var categories: ReportFilterSelection
    var includesOffBudget: Bool
    var includesHiddenCategories: Bool
    var includesUncategorized: Bool

    static let `default` = Self(
        accounts: .all,
        categories: .all,
        includesOffBudget: false,
        includesHiddenCategories: true,
        includesUncategorized: true
    )
}

struct ReportExplorerAccountFilterOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isOffBudget: Bool
    let isClosed: Bool
}

struct ReportExplorerCategoryFilterOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let groupID: String?
    let groupName: String
    let isIncome: Bool
    let isHidden: Bool
}

struct ReportExplorerFilterCatalog: Hashable, Sendable {
    let accounts: [ReportExplorerAccountFilterOption]
    let categories: [ReportExplorerCategoryFilterOption]

    static let empty = Self(accounts: [], categories: [])

    func categories(for metric: ReportExplorerMetric) -> [ReportExplorerCategoryFilterOption] {
        metric == .cashFlow ? categories : categories.filter { !$0.isIncome }
    }
}

struct ReportExplorerFilterDraft: Hashable, Sendable {
    var filters: ReportExplorerFilters

    init(filters: ReportExplorerFilters) {
        self.filters = filters
    }

    func isAccountSelected(_ id: String) -> Bool {
        isSelected(id, in: filters.accounts)
    }

    func isCategorySelected(_ id: String) -> Bool {
        isSelected(id, in: filters.categories)
    }

    mutating func setAccount(
        _ id: String,
        selected: Bool,
        availableIDs: Set<String>
    ) {
        filters.accounts = updatedSelection(
            filters.accounts,
            id: id,
            selected: selected,
            availableIDs: availableIDs
        )
    }

    mutating func setCategory(
        _ id: String,
        selected: Bool,
        availableIDs: Set<String>
    ) {
        filters.categories = updatedSelection(
            filters.categories,
            id: id,
            selected: selected,
            availableIDs: availableIDs
        )
    }

    mutating func selectAllAccounts() {
        filters.accounts = .all
    }

    mutating func clearAccounts() {
        filters.accounts = .only([])
    }

    mutating func selectAllCategories() {
        filters.categories = .all
    }

    mutating func clearCategories() {
        filters.categories = .only([])
        filters.includesUncategorized = false
    }

    private func isSelected(_ id: String, in selection: ReportFilterSelection) -> Bool {
        switch selection {
        case .all:
            true
        case .only(let ids):
            ids.contains(id)
        }
    }

    private func updatedSelection(
        _ selection: ReportFilterSelection,
        id: String,
        selected: Bool,
        availableIDs: Set<String>
    ) -> ReportFilterSelection {
        var selectedIDs: Set<String>
        switch selection {
        case .all:
            selectedIDs = availableIDs
        case .only(let ids):
            selectedIDs = ids
        }
        if selected {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
        return selectedIDs == availableIDs ? .all : .only(selectedIDs)
    }
}

extension ReportExplorerMetric {
    var supportsCategoryFilters: Bool { self != .netWorth }
    var supportsActivityVisibility: Bool { self != .netWorth }
}

enum ReportDrilldownUnavailableReason: Hashable, Sendable {
    case balanceSnapshot
    case noContributingTransactions
}

enum ReportDrilldownAvailability: Hashable, Sendable {
    case transactions(TransactionDrilldownRequest)
    case unavailable(ReportDrilldownUnavailableReason)
}

extension ReportDrilldownAvailability {
    var request: TransactionDrilldownRequest? {
        guard case .transactions(let request) = self else { return nil }
        return request
    }
}

struct ReportTransactionDrilldownSnapshot: Hashable, Sendable {
    let request: TransactionDrilldownRequest
    let loaded: LoadedAccountTransactions
    let contributingTransactionIDs: Set<String>
}
