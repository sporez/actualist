import Foundation
import Testing
@testable import Actualist

/// Concurrency remediation 4.8: widget publication debounces a burst of
/// revisions, remembers what it last wrote, and reloads timelines only when it
/// changed or removed something.
@MainActor
struct WidgetSnapshotCoordinatorTests {
    private final class Counters {
        var reads = 0
        var reloads = 0
    }

    private struct Harness {
        let coordinator: WidgetSnapshotCoordinator
        let store: WidgetSnapshotStore
        let counters: Counters
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        /// The coordinator holds AppState weakly.
        let state: AppState
    }

    private func makeHarness(seed: WidgetSnapshot? = nil) throws -> Harness {
        let suite = "WidgetSnapshotCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WidgetCoordinator-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = WidgetSnapshotStore(directoryURL: directory)
        if let seed { try store.save(seed) }
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))
        state.settings.selectedBudgetID = "budget"
        state.settings.selectedBudgetName = "Household"
        let counters = Counters()
        let coordinator = WidgetSnapshotCoordinator(
            snapshotStore: store,
            themeStore: WidgetThemeStore(defaults: nil),
            publishDelay: .milliseconds(30),
            reloadAllTimelines: { counters.reloads += 1 },
            loadSource: { _, _ in
                counters.reads += 1
                return Self.makeSource()
            }
        )
        coordinator.configure(appState: state, snapshotStore: store)
        counters.reloads = 0 // Theme publication during configure is not under test.
        return Harness(coordinator: coordinator, store: store, counters: counters,
                       directory: directory, defaults: defaults, suite: suite, state: state)
    }

    private func finish(_ harness: Harness) {
        harness.defaults.removePersistentDomain(forName: harness.suite)
        try? FileManager.default.removeItem(at: harness.directory)
    }

    @Test func firstPublicationOfABurstWritesAndReloadsOnce() async throws {
        let harness = try makeHarness()
        defer { finish(harness) }
        harness.coordinator.beginFinancialPublication()
        for _ in 0..<5 { harness.coordinator.refresh() }
        await harness.coordinator.waitForPendingPublication()

        #expect(harness.counters.reads == 1, "burst read the budget more than once")
        #expect(harness.counters.reloads == 1, "burst reloaded timelines more than once")
        #expect(harness.store.load()?.budgetID == "budget")
    }

    @Test func identicalContentIsNotRewrittenFromMemory() async throws {
        let harness = try makeHarness()
        defer { finish(harness) }
        harness.coordinator.beginFinancialPublication()
        await harness.coordinator.waitForPendingPublication()
        #expect(harness.counters.reloads == 1)

        // If the coordinator re-read the file to compare, it would notice this
        // and rewrite; it trusts what it wrote.
        harness.store.clear()
        harness.coordinator.refresh()
        await harness.coordinator.waitForPendingPublication()

        #expect(harness.store.load() == nil)
        #expect(harness.counters.reloads == 1)
    }

    @Test func clearingReloadsTimelinesOnlyWhenASnapshotWasRemoved() throws {
        let seed = Self.makeSnapshot()
        let harness = try makeHarness(seed: seed)
        defer { finish(harness) }

        harness.coordinator.clearSnapshot()
        #expect(harness.store.load() == nil)
        #expect(harness.counters.reloads == 1)

        harness.coordinator.clearSnapshot()
        #expect(harness.counters.reloads == 1, "a clear that removed nothing reloaded timelines")
    }

    private static func makeSnapshot() -> WidgetSnapshot {
        WidgetFinancialSnapshotBuilder.make(
            source: makeSource(), budgetID: "budget", budgetName: "Household", privacyEnabled: false
        )
    }

    private static func makeSource() -> WidgetBudgetSource {
        let category = BudgetMonthCategory(id: "category", name: "Food", isIncome: false, hidden: false, groupID: "group", budgeted: 10000, spent: -12500, balance: -2500, carryover: false)
        let group = BudgetMonthCategoryGroup(id: "group", name: "Group", isIncome: false, hidden: false, budgeted: 10000, spent: -12500, balance: -2500, categories: [category])
        let month = BudgetMonth(month: WidgetMonthID.current(), incomeAvailable: 0, lastMonthOverspent: 0, forNextMonth: 0, totalBudgeted: 10000, toBudget: 15000, fromLastMonth: 0, totalIncome: 400000, totalSpent: -12500, totalBalance: -2500, categoryGroups: [group])
        return WidgetBudgetSource(
            month: month, currency: .usd, accounts: nil, attention: nil, recentTransactions: nil,
            transactionLookup: TransactionRowLookup(payeeNames: [:]), netWorth: nil
        )
    }
}
