import Foundation

enum ReportFilterSelection: Hashable, Sendable {
    case all
    case only(Set<String>)

    var isAll: Bool {
        if case .all = self { true } else { false }
    }
}

/// Which transfers a cash-flow read counts. `transfers` (transfers only) comes
/// from an Actual Calendar card whose conditions say `transfer is true`.
enum ReportTransferFilter: Hashable, Sendable {
    case all
    case transfers
    case nonTransfers
}

struct ReportExplorerFilters: Hashable, Sendable {
    var accounts: ReportFilterSelection
    var categories: ReportFilterSelection
    var includesOffBudget: Bool
    var includesHiddenCategories: Bool
    var includesUncategorized: Bool
    var transfers: ReportTransferFilter = .nonTransfers

    /// Net worth counts every account, matching the Reports dashboard card;
    /// activity reports start from on-budget accounts.
    static func defaults(for metric: ReportExplorerMetric) -> Self {
        Self(
            accounts: .all,
            categories: .all,
            includesOffBudget: metric == .netWorth,
            includesHiddenCategories: true,
            includesUncategorized: true
        )
    }
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

/// Edits filters so every row shows whether the report counts it. Off-budget
/// accounts and hidden categories only count while their include switch is on,
/// so a row in that gated group reads off while the switch is off, and turning
/// one on opens the switch for that row alone.
struct ReportExplorerFilterDraft: Hashable, Sendable {
    var filters: ReportExplorerFilters
    private let defaults: ReportExplorerFilters
    private let accountIDs: Set<String>
    private let offBudgetAccountIDs: Set<String>
    private let categoryIDs: Set<String>
    private let hiddenCategoryIDs: Set<String>

    init(
        filters: ReportExplorerFilters,
        defaults: ReportExplorerFilters,
        accounts: [ReportExplorerAccountFilterOption],
        categories: [ReportExplorerCategoryFilterOption]
    ) {
        self.filters = filters
        self.defaults = defaults
        accountIDs = Set(accounts.map(\.id))
        offBudgetAccountIDs = Set(accounts.lazy.filter(\.isOffBudget).map(\.id))
        categoryIDs = Set(categories.map(\.id))
        hiddenCategoryIDs = Set(categories.lazy.filter(\.isHidden).map(\.id))
    }

    func isAccountIncluded(_ id: String) -> Bool {
        (filters.includesOffBudget || !offBudgetAccountIDs.contains(id))
            && Self.isSelected(id, in: filters.accounts)
    }

    func isCategoryIncluded(_ id: String) -> Bool {
        (filters.includesHiddenCategories || !hiddenCategoryIDs.contains(id))
            && Self.isSelected(id, in: filters.categories)
    }

    mutating func setAccount(_ id: String, included: Bool) {
        Self.setRow(
            id,
            included: included,
            selection: &filters.accounts,
            gateIsOpen: &filters.includesOffBudget,
            availableIDs: accountIDs,
            gatedIDs: offBudgetAccountIDs
        )
    }

    mutating func setCategory(_ id: String, included: Bool) {
        Self.setRow(
            id,
            included: included,
            selection: &filters.categories,
            gateIsOpen: &filters.includesHiddenCategories,
            availableIDs: categoryIDs,
            gatedIDs: hiddenCategoryIDs
        )
    }

    mutating func setIncludesOffBudget(_ included: Bool) {
        Self.setGate(
            included,
            selection: &filters.accounts,
            gateIsOpen: &filters.includesOffBudget,
            availableIDs: accountIDs,
            gatedIDs: offBudgetAccountIDs
        )
    }

    mutating func setIncludesHiddenCategories(_ included: Bool) {
        Self.setGate(
            included,
            selection: &filters.categories,
            gateIsOpen: &filters.includesHiddenCategories,
            availableIDs: categoryIDs,
            gatedIDs: hiddenCategoryIDs
        )
    }

    mutating func selectAllAccounts() {
        filters.accounts = .all
        filters.includesOffBudget = true
    }

    mutating func clearAccounts() {
        filters.accounts = .only([])
        filters.includesOffBudget = false
    }

    mutating func selectAllCategories() {
        filters.categories = .all
        filters.includesHiddenCategories = true
        filters.includesUncategorized = true
    }

    mutating func clearCategories() {
        filters.categories = .only([])
        filters.includesHiddenCategories = false
        filters.includesUncategorized = false
    }

    var includesTransfers: Bool {
        filters.transfers != .nonTransfers
    }

    mutating func setIncludesTransfers(_ included: Bool) {
        filters.transfers = included ? .all : .nonTransfers
    }

    mutating func reset() {
        filters = defaults
    }

    private static func isSelected(_ id: String, in selection: ReportFilterSelection) -> Bool {
        switch selection {
        case .all:
            true
        case .only(let ids):
            ids.contains(id)
        }
    }

    private static func selectedIDs(
        _ selection: ReportFilterSelection,
        availableIDs: Set<String>
    ) -> Set<String> {
        switch selection {
        case .all: availableIDs
        case .only(let ids): ids
        }
    }

    private static func normalized(
        _ selectedIDs: Set<String>,
        availableIDs: Set<String>
    ) -> ReportFilterSelection {
        selectedIDs == availableIDs ? .all : .only(selectedIDs)
    }

    /// Opening a closed gate from one row adds only that row: the other gated
    /// rows read off while the gate is closed, so they stay off.
    private static func setRow(
        _ id: String,
        included: Bool,
        selection: inout ReportFilterSelection,
        gateIsOpen: inout Bool,
        availableIDs: Set<String>,
        gatedIDs: Set<String>
    ) {
        var ids = selectedIDs(selection, availableIDs: availableIDs)
        if included {
            if gatedIDs.contains(id), !gateIsOpen {
                ids.subtract(gatedIDs)
                gateIsOpen = true
            }
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        selection = normalized(ids, availableIDs: availableIDs)
    }

    /// Opening the gate turns every gated row on. Closing it leaves the
    /// selection alone because the gate already excludes those rows.
    private static func setGate(
        _ open: Bool,
        selection: inout ReportFilterSelection,
        gateIsOpen: inout Bool,
        availableIDs: Set<String>,
        gatedIDs: Set<String>
    ) {
        gateIsOpen = open
        guard open else { return }
        let ids = selectedIDs(selection, availableIDs: availableIDs).union(gatedIDs)
        selection = normalized(ids, availableIDs: availableIDs)
    }
}

extension ReportExplorerMetric {
    var supportsCategoryFilters: Bool { self != .netWorth }
    var supportsActivityVisibility: Bool { self != .netWorth }
    var supportsTransferFilter: Bool { self == .cashFlow }
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
