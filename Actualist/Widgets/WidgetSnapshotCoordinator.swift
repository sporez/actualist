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

/// Publishes a current-budget display snapshot into the App Group container
/// so widget extensions can render without opening SQLite.
@MainActor
final class WidgetSnapshotCoordinator {
    static let shared = WidgetSnapshotCoordinator()

    private weak var appState: AppState?
    private var snapshotStore: WidgetSnapshotStore
    private var isArmed = false
    private var publicationGeneration = WidgetSnapshotPublicationGeneration()
    private var publishTask: Task<Void, Never>?
    private let themeStore: WidgetThemeStore
    private let reloadAllTimelines: () -> Void

    init(
        snapshotStore: WidgetSnapshotStore = .live,
        themeStore: WidgetThemeStore = .live,
        reloadAllTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.snapshotStore = snapshotStore
        self.themeStore = themeStore
        self.reloadAllTimelines = reloadAllTimelines
    }

    func configure(appState: AppState, snapshotStore: WidgetSnapshotStore = .live) {
        self.appState = appState
        self.snapshotStore = snapshotStore
        guard !isArmed else {
            return
        }
        isArmed = true
        armTheme()
        arm()
        enqueuePublish()
    }

    private func armTheme() {
        guard let appState else { return }
        let theme = withObservationTracking {
            appState.settings.theme
        } onChange: { [weak self] in
            Task { @MainActor in self?.armTheme() }
        }
        if themeStore.saveIfChanged(theme) {
            reloadAllTimelines()
        }
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
        let budgetName = appState.settings.selectedBudgetName ?? ""
        let privacyEnabled = appState.settings.randomizedDisplayValuesEnabled
        if let previous = snapshotStore.load(),
           previous.budgetID != budgetID || previous.privacyEnabled != privacyEnabled {
            replaceSnapshot(nil)
        }
        guard appState.localFirstStore.isOpen(budgetID: budgetID) else { return }
        do {
            let source = try await appState.localFirstStore.fetchWidgetSource(budgetID: budgetID)
            guard !Task.isCancelled, publicationGeneration.isCurrent(generation),
                  appState.settings.selectedBudgetID == budgetID,
                  appState.settings.randomizedDisplayValuesEnabled == privacyEnabled else { return }
            let snapshot = WidgetFinancialSnapshotBuilder.make(
                source: source, budgetID: budgetID, budgetName: budgetName,
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
        } else {
            snapshotStore.clear()
        }
        for kind in WidgetKind.dataWidgets {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}
