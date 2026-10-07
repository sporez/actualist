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
    /// A burst of revisions collapses into one read and write after this quiet period.
    private let publishDelay: Duration
    /// Returns nil when the budget is not ready to publish (setup incomplete or not open).
    private let loadSource: @MainActor (AppState, String) async throws -> WidgetBudgetSource?
    /// What this process last wrote (or found on disk once), so a revision does not
    /// re-read and re-decode the file just to compare it. Nil means no saved snapshot.
    private var lastWritten: WidgetSnapshot?
    private var hasSeededLastWritten = false
    /// Bumped by every clear, so a write that was in flight can remove what it just wrote.
    private var clearEpoch = 0

    init(
        snapshotStore: WidgetSnapshotStore = .live,
        themeStore: WidgetThemeStore = .live,
        publishDelay: Duration = .milliseconds(300),
        reloadAllTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        loadSource: @escaping @MainActor (AppState, String) async throws -> WidgetBudgetSource? = { appState, budgetID in
            guard appState.setupPhase == .ready,
                  appState.localFirstStore.isOpen(budgetID: budgetID) else { return nil }
            return try await appState.localFirstStore.fetchWidgetSource(budgetID: budgetID)
        }
    ) {
        self.snapshotStore = snapshotStore
        self.themeStore = themeStore
        self.publishDelay = publishDelay
        self.reloadAllTimelines = reloadAllTimelines
        self.loadSource = loadSource
    }

    func configure(appState: AppState, snapshotStore: WidgetSnapshotStore = .live) {
        self.appState = appState
        self.snapshotStore = snapshotStore
        lastWritten = nil
        hasSeededLastWritten = false
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

    /// Removes the saved snapshot now and invalidates any in-flight publish, so
    /// sign-out never waits on the asynchronous observation path.
    func clearSnapshot() {
        _ = publicationGeneration.begin()
        publishTask?.cancel()
        publishTask = nil
        removeSnapshot()
    }

    func refresh() {
        let generation = publicationGeneration.begin()
        publishTask?.cancel()
        publishTask = Task { @MainActor [weak self, publishDelay] in
            do {
                try await Task.sleep(for: publishDelay)
            } catch {
                return // Superseded by a newer revision inside the quiet period.
            }
            await self?.publish(generation: generation)
        }
    }

    /// Completes once the newest scheduled publication has finished or been superseded.
    func waitForPendingPublication() async {
        await publishTask?.value
    }

    private func publish(generation: Int) async {
        guard let appState else {
            return
        }

        guard let budgetID = appState.settings.selectedBudgetID,
              !budgetID.isEmpty else {
            removeSnapshot()
            return
        }
        let budgetName = appState.settings.selectedBudgetName ?? ""
        let privacyEnabled = appState.settings.randomizedDisplayValuesEnabled
        await seedLastWritten()
        guard !Task.isCancelled, publicationGeneration.isCurrent(generation) else { return }
        if let previous = lastWritten,
           previous.budgetID != budgetID || previous.privacyEnabled != privacyEnabled {
            removeSnapshot()
        }
        guard financialPublicationGate.isActive else { return }
        do {
            guard let source = try await loadSource(appState, budgetID) else { return }
            guard !Task.isCancelled, publicationGeneration.isCurrent(generation),
                  appState.settings.selectedBudgetID == budgetID,
                  appState.settings.randomizedDisplayValuesEnabled == privacyEnabled else { return }
            let snapshot = WidgetFinancialSnapshotBuilder.make(
                source: source, budgetID: budgetID, budgetName: budgetName,
                privacyEnabled: privacyEnabled
            )
            await write(snapshot)
        } catch {
            // Keep the last good snapshot on a transient read failure.
        }
    }

    /// Reads the saved file once per store, off the main thread.
    private func seedLastWritten() async {
        guard !hasSeededLastWritten else { return }
        let store = snapshotStore
        let saved = await store.loadOffMain()
        guard !hasSeededLastWritten else { return }
        lastWritten = saved
        hasSeededLastWritten = true
    }

    private func write(_ snapshot: WidgetSnapshot) async {
        if lastWritten?.hasSameDisplayContent(as: snapshot) == true { return }
        let epoch = clearEpoch
        do {
            try await snapshotStore.saveOffMain(snapshot)
        } catch {
            return
        }
        guard epoch == clearEpoch else {
            // A sign-out or budget switch cleared while this write was in flight.
            snapshotStore.clear()
            return
        }
        lastWritten = snapshot
        reloadAllTimelines()
    }

    private func removeSnapshot() {
        clearEpoch &+= 1
        lastWritten = nil
        hasSeededLastWritten = true
        if snapshotStore.clear() {
            reloadAllTimelines()
        }
    }
}
