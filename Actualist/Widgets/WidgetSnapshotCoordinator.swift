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

struct WidgetFinancialPublicationGate {
    private var generation = 0
    private(set) var activeGeneration: Int?

    var isActive: Bool { activeGeneration != nil }

    mutating func begin() -> Int {
        if let activeGeneration { return activeGeneration }
        generation &+= 1
        activeGeneration = generation
        return generation
    }

    mutating func end() {
        activeGeneration = nil
    }

    func accepts(_ candidate: Int) -> Bool {
        activeGeneration == candidate
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
    private var financialPublicationGate = WidgetFinancialPublicationGate()
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
        refresh()
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

    private func armFinancialObservation(generation: Int) {
        guard financialPublicationGate.accepts(generation), let appState else { return }
        withObservationTracking {
            _ = appState.settings.selectedBudgetID
            _ = appState.settings.selectedBudgetName
            _ = appState.settings.randomizedDisplayValuesEnabled
            _ = appState.localDataRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.financialPublicationGate.accepts(generation) else { return }
                self.refresh()
                self.armFinancialObservation(generation: generation)
            }
        }
    }

    /// Widget finance reads stay dormant until the Budget host reports its first
    /// frame. This prevents setup observation from competing with launch seeding.
    func beginFinancialPublication() {
        let wasActive = financialPublicationGate.isActive
        let generation = financialPublicationGate.begin()
        if !wasActive {
            armFinancialObservation(generation: generation)
        }
        refresh()
    }

    func endFinancialPublication() {
        financialPublicationGate.end()
        _ = publicationGeneration.begin()
        publishTask?.cancel()
        publishTask = nil
        refresh()
    }

    func refresh() {
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
        guard financialPublicationGate.isActive,
              appState.setupPhase == .ready,
              appState.localFirstStore.isOpen(budgetID: budgetID) else { return }
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
