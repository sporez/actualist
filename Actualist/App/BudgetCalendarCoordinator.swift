import Foundation

/// Calendar invalidation is local: closing a month never waits for sync.
@MainActor
final class BudgetCalendarCoordinator: NSObject {
    static let shared = BudgetCalendarCoordinator()

    private weak var appState: AppState?
    private var boundaryTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?
    private var generation = 0
    private(set) var currentMonth: String?
    private var timeZoneID: String?
    private let now: @MainActor () -> Date
    private let currentTimeZoneID: @MainActor () -> String
    private let publishWidgets: @MainActor () -> Void

    init(now: @escaping @MainActor () -> Date = { Date() },
         currentTimeZoneID: @escaping @MainActor () -> String = { TimeZone.autoupdatingCurrent.identifier },
         publishWidgets: @escaping @MainActor () -> Void = { WidgetSnapshotCoordinator.shared.refresh() }) {
        self.now = now
        self.currentTimeZoneID = currentTimeZoneID
        self.publishWidgets = publishWidgets
        super.init()
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged), name: name, object: nil)
        }
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    @discardableResult
    func beginForeground(forceRefresh: Bool = false) -> Task<Void, Never>? {
        guard boundaryTask == nil else { return foregroundRefreshTask }
        generation &+= 1
        let requested = generation
        let refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(force: forceRefresh, generation: requested)
        }
        foregroundRefreshTask = refreshTask
        boundaryTask = Task { [weak self] in
            await refreshTask.value
            while !Task.isCancelled {
                guard let date = self?.now() else { return }
                let delay = max(1, WidgetMonthID.nextBoundary(after: date, graceInterval: 0).timeIntervalSince(date))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, requested == self.generation else { return }
                await self.refresh(force: false, generation: requested)
            }
        }
        return refreshTask
    }

    func endForeground() {
        generation &+= 1
        boundaryTask?.cancel()
        boundaryTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }

    @objc nonisolated private func calendarChanged() {
        Task { @MainActor [weak self] in
            guard let self, self.boundaryTask != nil else { return }
            self.endForeground()
            self.beginForeground(forceRefresh: true)
        }
    }

    func refresh(force: Bool = false) async {
        await refresh(force: force, generation: generation)
    }

    private func refresh(force: Bool, generation requested: Int) async {
        guard !Task.isCancelled, requested == generation else { return }
        let date = now()
        let month = WidgetMonthID.current(now: date)
        let zone = currentTimeZoneID()
        guard force || month != currentMonth || zone != timeZoneID else { return }
        guard let appState else { return }
        if let budgetID = appState.settings.selectedBudgetID,
           appState.localFirstStore.isOpen(budgetID: budgetID) {
            try? await appState.localFirstStore.reloadSelectedBudgetCache(budgetID: budgetID, now: date)
        }
        guard !Task.isCancelled, requested == generation else { return }
        currentMonth = month
        timeZoneID = zone
        // Also redraw cached summaries if a local read failed. Their typed
        // planned/actual values can select the new headline without SQLite.
        appState.recordLocalDataMutation()
        publishWidgets()
    }
}
