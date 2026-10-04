import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetCalendarCoordinatorTests {
    @Test func repeatedForegroundReturnDoesNotReloadAnUnchangedCalendarContext() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        var publications = 0
        let coordinator = BudgetCalendarCoordinator(
            now: { Self.date("2026-07") },
            publishWidgets: { publications += 1 }
        )
        coordinator.configure(appState: appState)

        await coordinator.beginForeground()?.value
        let revisionAfterFirstRefresh = appState.localDataRevision
        coordinator.endForeground()

        await coordinator.beginForeground()?.value

        #expect(appState.localDataRevision == revisionAfterFirstRefresh)
        #expect(publications == 1)
        #expect(coordinator.currentMonth == "2026-07")
        #expect(coordinator.currentDay != nil)
        coordinator.endForeground()
    }

    @Test func foregroundReturnRefreshesWhenTheLocalDayChangedWithinTheSameMonth() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        let timeZoneID = "America/Los_Angeles"
        var clock = Self.dayDate("2026-07-01", timeZoneID: timeZoneID)
        var publications = 0
        let coordinator = BudgetCalendarCoordinator(
            now: { clock },
            currentTimeZoneID: { timeZoneID },
            publishWidgets: { publications += 1 }
        )
        coordinator.configure(appState: appState)

        await coordinator.beginForeground()?.value
        coordinator.endForeground()
        let revisionBeforeReturn = appState.localDataRevision
        clock = Self.dayDate("2026-07-02", timeZoneID: timeZoneID)

        await coordinator.beginForeground()?.value

        #expect(coordinator.currentMonth == "2026-07")
        #expect(coordinator.currentDay == "2026-07-02")
        #expect(appState.localDataRevision == revisionBeforeReturn + 1)
        #expect(publications == 2)
        coordinator.endForeground()
    }

    @Test func foregroundReturnRefreshesWhenTheMonthChanged() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        var clock = Self.date("2026-07")
        var publications = 0
        let coordinator = BudgetCalendarCoordinator(
            now: { clock },
            publishWidgets: { publications += 1 }
        )
        coordinator.configure(appState: appState)

        await coordinator.beginForeground()?.value
        coordinator.endForeground()
        let revisionBeforeReturn = appState.localDataRevision
        clock = Self.date("2026-08")

        await coordinator.beginForeground()?.value

        #expect(coordinator.currentMonth == "2026-08")
        #expect(appState.localDataRevision == revisionBeforeReturn + 1)
        #expect(publications == 2)
        coordinator.endForeground()
    }

    @Test func timezoneChangeAndForcedCalendarRefreshPublishForTheSameMonth() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        let zone = TimeZoneSource()
        var publications = 0
        let coordinator = BudgetCalendarCoordinator(
            now: { Self.date("2026-07") },
            currentTimeZoneID: { zone.id },
            publishWidgets: { publications += 1 }
        )
        coordinator.configure(appState: appState)

        await coordinator.refresh()
        let revisionAfterInitialRefresh = appState.localDataRevision
        zone.id = "Pacific/Auckland"
        await coordinator.refresh()
        #expect(appState.localDataRevision == revisionAfterInitialRefresh + 1)
        #expect(publications == 2)

        await coordinator.refresh(force: true)
        #expect(appState.localDataRevision == revisionAfterInitialRefresh + 2)
        #expect(publications == 3)
    }

    @Test func endingForegroundBeforeInitialRefreshPreventsStalePublication() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        var publications = 0
        let coordinator = BudgetCalendarCoordinator(
            now: { Self.date("2026-07") },
            publishWidgets: { publications += 1 }
        )
        coordinator.configure(appState: appState)

        let refresh = coordinator.beginForeground()
        coordinator.endForeground()
        await refresh?.value

        #expect(appState.localDataRevision == 0)
        #expect(publications == 0)
        #expect(coordinator.currentMonth == nil)

        await coordinator.beginForeground()?.value
        #expect(appState.localDataRevision == 1)
        #expect(publications == 1)
        coordinator.endForeground()
    }

    @Test func failedReloadDoesNotAdvanceTheDayAndTheNextRefreshRetries() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        var reloads = 0
        let coordinator = BudgetCalendarCoordinator(
            now: { Self.date("2026-07") },
            publishWidgets: {},
            reloadCache: { _, _, _ in
                reloads += 1
                if reloads == 1 { throw LocalFirstError.unsupportedWrite }
            }
        )
        coordinator.configure(appState: appState)

        await coordinator.refresh()
        #expect(reloads == 1)
        #expect(coordinator.currentDay == nil)
        #expect(coordinator.currentMonth == nil)

        await coordinator.refresh()
        #expect(reloads == 2)
        #expect(coordinator.currentDay != nil)
        #expect(coordinator.currentMonth == "2026-07")
    }

    @Test func budgetSwitchDuringReloadDoesNotAdvanceTheDay() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        let openBudgetID = appState.settings.selectedBudgetID
        var reloads = 0
        let coordinator = BudgetCalendarCoordinator(
            now: { Self.date("2026-07") },
            publishWidgets: {},
            reloadCache: { appState, _, _ in
                reloads += 1
                if reloads == 1 { appState.settings.selectedBudgetID = "another-budget" }
            }
        )
        coordinator.configure(appState: appState)

        await coordinator.refresh()
        #expect(coordinator.currentDay == nil)

        appState.settings.selectedBudgetID = openBudgetID
        await coordinator.refresh()
        #expect(reloads == 2)
        #expect(coordinator.currentDay != nil)
    }

    private static func date(_ month: String) -> Date {
        ReportCalendar.date(fromMonthID: month, calendar: ReportCalendar.gregorianLocal)!
    }

    private static func dayDate(_ day: String, timeZoneID: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        return ReportCalendar.date(fromDayID: day, calendar: calendar)!
    }

    @MainActor
    private final class TimeZoneSource {
        var id = "America/Los_Angeles"
    }
}
