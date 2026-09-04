import Foundation
import Observation
import WidgetKit

struct WidgetSnapshotPublicationGeneration {
    private var value = 0

    mutating func begin() -> Int {
        value &+= 1
        return value
    }

    func isCurrent(_ candidate: Int) -> Bool {
        value == candidate
    }
}

/// Publishes a current-month category snapshot into the App Group container
/// so widget extensions can render without opening SQLite.
@MainActor
final class WidgetSnapshotCoordinator {
    static let shared = WidgetSnapshotCoordinator()

    private weak var appState: AppState?
    private var snapshotStore: WidgetSnapshotStore
    private var isArmed = false
    private var publicationGeneration = WidgetSnapshotPublicationGeneration()
    private var publishTask: Task<Void, Never>?

    init(snapshotStore: WidgetSnapshotStore = .live) {
        self.snapshotStore = snapshotStore
    }

    func configure(appState: AppState, snapshotStore: WidgetSnapshotStore = .live) {
        self.appState = appState
        self.snapshotStore = snapshotStore
        guard !isArmed else {
            return
        }
        isArmed = true
        arm()
        enqueuePublish()
    }

    private func arm() {
        guard let appState else {
            return
        }
        withObservationTracking {
            _ = appState.setupPhase
            _ = appState.settings.selectedBudgetID
            _ = appState.settings.selectedBudgetName
            _ = appState.settings.randomizedDisplayValuesEnabled
            _ = appState.localDataRevision
            _ = appState.localFirstStore.openedBudgetID
            _ = appState.localFirstStore.loadedBudgetMonthsByBudget
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.enqueuePublish()
                self?.arm()
            }
        }
    }

    private func enqueuePublish() {
        let generation = publicationGeneration.begin()
        publishTask?.cancel()
        publishTask = Task { @MainActor [weak self] in
            await self?.publish(generation: generation)
        }
    }

    private func publish(generation: Int) async {
        guard let appState else {
            return
        }

        guard let budgetID = appState.settings.selectedBudgetID,
              !budgetID.isEmpty else {
            replaceSnapshot(nil)
            return
        }
        guard appState.localFirstStore.isOpen(budgetID: budgetID) else {
            if snapshotStore.load()?.budgetID != budgetID {
                replaceSnapshot(nil)
            }
            return
        }

        let monthID = WidgetMonthID.current()
        let budgetName = appState.settings.selectedBudgetName ?? ""
        let privacyEnabled = appState.settings.randomizedDisplayValuesEnabled
        do {
            let month: BudgetMonth
            let currency: BudgetCurrency
            if let cached = appState.localFirstStore.cachedBudgetMonth(budgetID: budgetID),
               cached.selectedMonth == monthID {
                month = cached.month
                currency = cached.currency
            } else {
                (month, currency) = try await appState.localFirstStore.fetchBudgetMonthUncached(
                    budgetID: budgetID,
                    month: monthID
                )
            }

            guard !Task.isCancelled, publicationGeneration.isCurrent(generation) else {
                return
            }
            let snapshot = WidgetSnapshotBuilder.make(
                budgetID: budgetID,
                budgetName: budgetName,
                month: month,
                currency: currency,
                privacyEnabled: privacyEnabled
            )
            replaceSnapshot(snapshot)
        } catch {
            // Keep the last good snapshot on a transient read failure.
        }
    }

    private func replaceSnapshot(_ snapshot: WidgetSnapshot?) {
        if let snapshot {
            if snapshotStore.load()?.hasSameDisplayContent(as: snapshot) == true {
                return
            }
            do {
                try snapshotStore.save(snapshot)
            } catch {
                return
            }
        } else if snapshotStore.load() != nil {
            snapshotStore.clear()
        } else {
            return
        }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.categoryBalance)
    }
}
