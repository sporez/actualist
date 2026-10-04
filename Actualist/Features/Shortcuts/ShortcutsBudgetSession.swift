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
    private var writeWaiters: [WriteWaiter] = []

    private struct WriteWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Writes waiting behind the active one. Observable so tests can wait for
    /// a queued write deterministically.
    var queuedWriteCount: Int { writeWaiters.count }

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
        try await acquireWrite()
        defer { finishWrite() }
        // A task cancelled while queued may already have been handed the lock.
        try Task.checkCancellation()
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
        case .category, .uncategorized, .history, .settings:
            appState.selectedTab = .budget
        case .newTransaction:
            break
        }
    }

    /// Returns owning the write lock, or throws without owning it when the
    /// task is cancelled while queued.
    private func acquireWrite() async throws {
        guard isWriting else {
            isWriting = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    writeWaiters.append(WriteWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelQueuedWrite(id) }
        }
    }

    private func cancelQueuedWrite(_ id: UUID) {
        guard let index = writeWaiters.firstIndex(where: { $0.id == id }) else { return }
        writeWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Ownership passes straight to the next waiter, so `isWriting` stays true
    /// across the hand-off and a newly arriving write cannot jump the queue.
    private func finishWrite() {
        guard !writeWaiters.isEmpty else {
            isWriting = false
            return
        }
        writeWaiters.removeFirst().continuation.resume()
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
        includeIncome: Bool? = nil,
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
            if !(includeIncome ?? month.isTrackingBudget), category.isIncome {
                return nil
            }
            if let query, !ShortcutEntityMatching.name(category.name, matches: query) {
                return nil
            }
            return CategoryEntity.make(
                from: category,
                groupName: groupNames[category.groupID] ?? "",
                currency: month.currency,
                isHidden: isHidden,
                isTrackingBudget: month.isTrackingBudget
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
        let selected = preferred ?? prepared.store.cachedBudgetMonth(budgetID: prepared.budgetID)?.selectedMonth
            ?? WidgetMonthID.current()
        return try await prepared.store.readBudgetMonth(budgetID: prepared.budgetID, month: selected)
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
        ActualBudget.resolved(
            budgetID: budgetID,
            selectedBudget: appState.selectedBudget,
            budgets: appState.budgets,
            settings: settings
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
