import AppIntents
import Foundation

struct PreparedBudget {
    let budgetID: String
    let store: LocalFirstActualStore
    let defaultAccountID: String?

    @MainActor
    var currency: BudgetCurrency {
        store.budgetCurrency(budgetID: budgetID)
    }
}

extension ShortcutsBudgetSession {
    func budgetCurrency() async throws -> BudgetCurrency {
        try await prepare().currency
    }

    func minorUnits(from amount: IntentCurrencyAmount) async throws -> Int {
        try ShortcutMoney.minorUnits(from: amount, currency: try await budgetCurrency())
    }

    func spoken(_ amount: IntentCurrencyAmount?) async throws -> String {
        ShortcutMoney.spoken(amount, currency: try await budgetCurrency())
    }

    func spoken(minorUnits: Int) async throws -> String {
        ShortcutMoney.spoken(minorUnits: minorUnits, currency: try await budgetCurrency())
    }
}

@MainActor
final class ShortcutsBudgetSession {
    private let appState: AppState
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    init(appState: AppState) {
        self.appState = appState
    }

    func requireEnabled() throws {
        guard appState.settings.shortcutsEnabled else {
            throw ShortcutsError.shortcutsDisabled
        }
    }

    @discardableResult
    func prepare() async throws -> PreparedBudget {
        try requireEnabled()
        if appState.isBudgetSwitchInProgress {
            throw ShortcutsError.budgetBusy
        }
        let settings = appState.settings
        guard appState.setupPhase != .needsConnection,
              let budgetID = settings.selectedBudgetID,
              !budgetID.isEmpty else {
            throw ShortcutsError.noBudgetSelected
        }

        let store = appState.localFirstStore
        if store.isOpen(budgetID: budgetID) {
            return preparedBudget(budgetID: budgetID, store: store, settings: settings)
        }
        if store.hasOpenBudget || appState.isBudgetSwitchInProgress {
            throw ShortcutsError.budgetBusy
        }

        guard let budget = reconstructedBudget(budgetID: budgetID, settings: settings) else {
            throw ShortcutsError.noBudgetSelected
        }

        do {
            let didOpen = try await store.openCachedBudget(budget)
            guard didOpen, store.isOpen(budgetID: budgetID) else {
                throw ShortcutsError.budgetFileMissing
            }
        } catch {
            throw ShortcutsError.mapping(error, fallback: .budgetFileMissing)
        }

        if appState.isBudgetSwitchInProgress {
            throw ShortcutsError.budgetBusy
        }
        return preparedBudget(budgetID: budgetID, store: store, settings: settings)
    }

    func withExclusiveWrite<T: Sendable>(
        _ work: @MainActor (PreparedBudget) async throws -> T
    ) async throws -> T {
        if isWriting {
            await withCheckedContinuation { continuation in
                writeWaiters.append(continuation)
            }
        }
        isWriting = true
        defer { finishWrite() }
        if appState.isBudgetSwitchInProgress {
            throw ShortcutsError.budgetBusy
        }
        let prepared = try await prepare()
        guard prepared.store.isOpen(budgetID: prepared.budgetID),
              !appState.isBudgetSwitchInProgress else {
            throw ShortcutsError.budgetBusy
        }
        do {
            return try await work(prepared)
        } catch {
            throw ShortcutsError.mapping(error)
        }
    }

    func recordSuccessfulWrite() {
        appState.recordLocalDataMutation()
    }

    func enqueueRoute(_ route: AppRoute) throws {
        try requireEnabled()
        appState.routeCoordinator.enqueue(route)
        switch route {
        case .tab(let tab):
            appState.accountNavigationPath = []
            appState.selectedTab = tab
        case .account:
            appState.selectedTab = .accounts
        case .category, .uncategorized, .settings:
            appState.selectedTab = .budget
        case .newTransaction:
            break
        }
    }

    private func finishWrite() {
        isWriting = false
        if !writeWaiters.isEmpty {
            writeWaiters.removeFirst().resume()
        }
    }

    func accounts(includeClosed: Bool, matching query: String? = nil) async throws -> [AccountEntity] {
        let prepared = try await prepare()
        var displays = prepared.store.accountDisplays(budgetID: prepared.budgetID)
        if displays.isEmpty {
            try await prepared.store.refreshAccountsWithBalances(budgetID: prepared.budgetID)
            displays = prepared.store.accountDisplays(budgetID: prepared.budgetID)
        }
        return displays.compactMap { display in
            if !includeClosed, display.account.closed {
                return nil
            }
            if let query, !ShortcutEntityMatching.name(display.account.name, matches: query) {
                return nil
            }
            return AccountEntity.make(from: display, currency: prepared.currency)
        }
    }

    func categories(
        includeHidden: Bool,
        includeIncome: Bool = false,
        matching query: String? = nil,
        month preferredMonth: String? = nil
    ) async throws -> [CategoryEntity] {
        let month = try await loadedMonth(preferred: preferredMonth)
        let groupNames = Dictionary(
            uniqueKeysWithValues: month.month.categoryGroups.map { ($0.id, $0.name) }
        )
        return month.month.categoryGroups.flatMap { group in
            group.categories.map { (group, $0) }
        }.compactMap { group, category in
            let isHidden = BudgetCategoryVisibility.isEffectivelyHidden(category: category, group: group)
            if !includeHidden, isHidden {
                return nil
            }
            if !includeIncome, category.isIncome {
                return nil
            }
            if let query, !ShortcutEntityMatching.name(category.name, matches: query) {
                return nil
            }
            return CategoryEntity.make(
                from: category,
                groupName: groupNames[category.groupID] ?? "",
                currency: month.currency,
                isHidden: isHidden
            )
        }
    }

    func payees(includeTransfers: Bool, matching query: String? = nil) async throws -> [PayeeEntity] {
        let prepared = try await prepare()
        if prepared.store.cachedPayeeManagementSnapshot(budgetID: prepared.budgetID) == nil {
            try await prepared.store.refreshPayeeManagementSnapshot(budgetID: prepared.budgetID)
        }
        let payees = prepared.store.cachedPayeeManagementSnapshot(budgetID: prepared.budgetID)?.payees ?? []
        return payees.compactMap { payee in
            if !includeTransfers, payee.isTransfer {
                return nil
            }
            if let query, !ShortcutEntityMatching.name(payee.displayName, matches: query) {
                return nil
            }
            return PayeeEntity.make(from: payee)
        }
    }

    func months(matching query: String? = nil) async throws -> [BudgetMonthEntity] {
        let month = try await loadedMonth()
        return month.availableMonths.compactMap { monthID in
            let entity = BudgetMonthEntity.make(monthID: monthID)
            if let query {
                let matchesID = ShortcutEntityMatching.name(monthID, matches: query)
                let matchesName = ShortcutEntityMatching.name(entity.name, matches: query)
                guard matchesID || matchesName else {
                    return nil
                }
            }
            return entity
        }
    }

    func loadedMonth(preferred: String? = nil) async throws -> LoadedBudgetMonth {
        let prepared = try await prepare()
        if let cached = prepared.store.cachedBudgetMonth(budgetID: prepared.budgetID) {
            if let preferred, preferred != cached.selectedMonth {
                return try await prepared.store.budgetMonth(
                    budgetID: prepared.budgetID,
                    selectedMonth: preferred
                )
            }
            return cached
        }
        if let preferred {
            return try await prepared.store.budgetMonth(
                budgetID: prepared.budgetID,
                selectedMonth: preferred
            )
        }
        let available = try await prepared.store.availableMonths(budgetID: prepared.budgetID)
        let selected = available.last ?? YearMonth(date: Date()).rawValue
        return try await prepared.store.currentBudgetMonth(
            budgetID: prepared.budgetID,
            preferredMonth: selected
        )
    }

    private func preparedBudget(
        budgetID: String,
        store: LocalFirstActualStore,
        settings: AppSettings
    ) -> PreparedBudget {
        PreparedBudget(
            budgetID: budgetID,
            store: store,
            defaultAccountID: settings.defaultAccountIDByBudgetID[budgetID]
        )
    }

    private func reconstructedBudget(budgetID: String, settings: AppSettings) -> ActualBudget? {
        if let selected = appState.selectedBudget, selected.syncID == budgetID {
            return selected
        }
        if let budget = appState.budgets.first(where: { $0.syncID == budgetID }) {
            return budget
        }
        guard let fileID = settings.selectedLocalFirstFileID else {
            return nil
        }
        return ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: settings.selectedLocalFirstGroupID,
            name: settings.selectedBudgetName ?? "Selected Budget",
            state: nil
        )
    }
}

enum ShortcutEntityMatching {
    static func name(_ name: String, matches query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return true
        }
        return name.localizedStandardContains(needle)
    }
}
