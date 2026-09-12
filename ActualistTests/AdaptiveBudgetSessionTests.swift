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
}
