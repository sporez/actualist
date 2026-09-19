import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test @MainActor
    func resizeRetainsPresentedHostUntilReplacementIsReady() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        let session = AdaptiveBudgetSession(repository: bundle.store)
        await session.update(mode: .compact, budgetID: "group-1", appState: appState).value

        let growing = session.update(mode: .sidebar, budgetID: "group-1", appState: appState)
        #expect(session.presentedContext == .init(mode: .compact, budgetID: "group-1"))
        await growing.value
        #expect(session.presentedContext == .init(mode: .sidebar, budgetID: "group-1"))

        let shrinking = session.update(mode: .compact, budgetID: "group-1", appState: appState)
        #expect(session.presentedContext == .init(mode: .sidebar, budgetID: "group-1"))
        let reversal = session.update(mode: .sidebar, budgetID: "group-1", appState: appState)
        await shrinking.value
        await reversal.value
        #expect(session.presentedContext == .init(mode: .sidebar, budgetID: "group-1"))

        let switching = session.update(mode: .sidebar, budgetID: "missing-budget", appState: appState)
        #expect(session.presentedContext == nil)
        await switching.value
        #expect(session.presentedContext?.budgetID == "missing-budget")
    }

    @Test @MainActor
    func adaptiveSessionPreservesCompactMonthAcrossWideRoundTrip() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        let session = AdaptiveBudgetSession(repository: bundle.store)

        await session.update(mode: .compact, budgetID: "group-1", appState: appState).value
        let selectedMonth = try #require(session.compactModel.selectedMonth)

        await session.update(mode: .sidebar, budgetID: "group-1", appState: appState).value
        await session.update(mode: .compact, budgetID: "group-1", appState: appState).value
        let changedMonth = BudgetViewportModel.monthID(selectedMonth, offsetBy: 1)
        await session.compactModel.selectMonth(
            changedMonth,
            budgetID: "group-1",
            repository: bundle.store
        )
        #expect(session.compactModel.selectedMonth == changedMonth)

        await session.update(mode: .sidebar, budgetID: "group-1", appState: appState).value

        #expect(session.viewport.anchorMonth == changedMonth)
        #expect(session.compactModel.selectedMonth == changedMonth)
    }

    @Test @MainActor
    func adaptiveSessionDoesNotLetFailedBudgetSwitchSeedOldViewport() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        let session = AdaptiveBudgetSession(repository: bundle.store)

        await session.update(mode: .compact, budgetID: "group-1", appState: appState).value
        await session.viewport.activate(
            budgetID: "group-1",
            compactModel: session.compactModel,
            monthCount: 1
        )

        await session.update(mode: .sidebar, budgetID: "missing-budget", appState: appState).value

        #expect(session.viewport.budgetID == "missing-budget")
        #expect(session.viewport.monthSnapshots.isEmpty)
        #expect(session.viewport.errorMessage != nil)
        #expect(session.compactModel.loadedBudgetID == nil)
    }

    @Test @MainActor
    func latestResizeRequestWins() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        let session = AdaptiveBudgetSession(repository: bundle.store)

        let first = session.update(mode: .compact, budgetID: "group-1", appState: appState)
        let second = session.update(mode: .sidebar, budgetID: "group-1", appState: appState)
        await first.value
        await second.value

        #expect(session.compactModel.loadedBudgetID == "group-1")
    }

    @Test @MainActor
    func restoredMonthIsHandedToTheCompactModelWithoutBeingReadAgain() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        let restored = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let repository = BudgetViewportTestRepository()
        await repository.set(restored)
        let session = AdaptiveBudgetSession(repository: repository)

        await session.update(mode: .compact, budgetID: "group-1", appState: appState).value

        #expect(await repository.currentBudgetMonthReadCount() == 0)
        #expect(await repository.budgetMonthReadCount(for: restored.month.month) == 0)
        #expect(session.compactModel.loadedBudgetID == "group-1")
        #expect(session.compactModel.selectedMonth == restored.month.month)
        #expect(session.compactModel.budgetMonth == restored.month)
        #expect(!session.compactModel.isLoading)
    }

    @Test @MainActor
    func anotherBudgetNeverSeedsTheCompactModelFromTheSelectedSnapshot() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        #expect(bundle.store.cachedBudgetMonth(budgetID: "group-1") != nil)
        let repository = BudgetViewportTestRepository()
        let preferred = YearMonth(date: Date()).rawValue
        let otherMonth = BudgetViewportFixtures.loaded(preferred, budgeted: 7)
        await repository.set(otherMonth)
        let session = AdaptiveBudgetSession(repository: repository)

        await session.update(mode: .compact, budgetID: "group-2", appState: appState).value

        #expect(await repository.currentBudgetMonthReadCount() == 1)
        #expect(session.compactModel.loadedBudgetID == "group-2")
        #expect(session.compactModel.budgetMonth == otherMonth.month)
    }

    @Test @MainActor
    func aLaunchThatRacedTheDatabaseOpenStillPresentsTheRestoredMonth() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        let restored = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let repository = BudgetViewportTestRepository()
        await repository.set(restored)
        let session = AdaptiveBudgetSession(repository: repository)
        // A launch can reach the session before the store has finished opening the
        // database, so nothing is cached and the read fails.
        bundle.store.reset()
        #expect(bundle.store.cachedBudgetMonth(budgetID: "group-1") == nil)
        await repository.setCurrentReadError(LocalFirstError.budgetNotOpened)

        await session.update(mode: .compact, budgetID: "group-1", appState: appState).value
        #expect(session.compactModel.budgetMonth == nil)
        #expect(session.compactModel.errorMessage != nil)

        // The store finishes opening; the next presentation request must retry
        // instead of presenting the empty model.
        _ = try await bundle.store.openCachedBudget(bundle.budget)
        await repository.setCurrentReadError(nil)
        await session.update(mode: .compact, budgetID: "group-1", appState: appState).value

        #expect(session.compactModel.budgetMonth == restored.month)
        #expect(session.compactModel.loadedBudgetID == "group-1")
        #expect(await repository.currentBudgetMonthReadCount() == 1)
    }
}
