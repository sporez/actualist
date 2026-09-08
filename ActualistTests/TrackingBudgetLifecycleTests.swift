import Foundation
import Testing
@testable import Actualist

@MainActor
struct TrackingBudgetLifecycleTests {
    static let sql = """
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
        INSERT INTO preferences VALUES ('budgetType', 'tracking');
        CREATE TABLE reflect_budgets (id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER, carryover INTEGER);
        INSERT INTO reflect_budgets VALUES ('202607-groceries', 202607, 'groceries', 500, 1);
        INSERT INTO reflect_budgets VALUES ('202608-groceries', 202608, 'groceries', 200, 0);
        INSERT INTO reflect_budgets VALUES ('202912-groceries', 202912, 'groceries', 700, 0);
        INSERT INTO category_groups VALUES ('income', 'Income', 1, 0, 0, 2);
        INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order) VALUES ('salary', 'Salary', 'income', 1, 0, 0, 1);
        INSERT INTO category_mapping VALUES ('salary', 'salary');
        INSERT INTO reflect_budgets VALUES ('202607-salary', 202607, 'salary', 1000, 0);
        """

    @Test func remoteConversionReplacesCachedMonthAndWidgetWithoutScreenRead() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.sql)
        let store = bundle.store
        let database = try #require(store.database)
        let tracking = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        for (index, type) in ["envelope", "tracking"].enumerated() {
            _ = try await database.applyRemoteSyncMessages([conversion(type, index: index)])
            try await store.reloadAfterRemoteSync(database: database, budgetID: "group-1")
            let cached = try #require(store.cachedBudgetMonth(budgetID: "group-1"))
            #expect(cached.isTrackingBudget == (type == "tracking"))
            #expect(cached.modeIdentity != tracking.modeIdentity)
            let source = try await store.fetchWidgetSource(budgetID: "group-1", now: date("2026-07"))
            let widget = WidgetFinancialSnapshotBuilder.make(source: source, budgetID: "group-1", budgetName: "Fixture", privacyEnabled: false, now: date("2026-07"))
            #expect(widget.isTrackingBudget == cached.isTrackingBudget)
            #expect((widget.overview?.toBudget == nil) == cached.isTrackingBudget)
        }
    }

    @Test func backdatedActivityReloadsLaterCachedRolloverAndExternalReadsKeepSelection() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.sql)
        let store = bundle.store
        let database = try #require(store.database)
        let before = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-08")
        _ = try await database.applyRemoteSyncMessages([ActualSyncDecodedMessage(timestamp: "2026-09-08T00:00:00.000Z-0000-0000000000000001", dataset: "transactions", row: "txn", column: "amount", serializedValue: "N:-100")])
        try await store.reloadAfterTransactionMutation(database: database, budgetID: "group-1", accountIDs: ["checking"], monthIDs: ["2026-07"])
        let cached = try #require(store.cachedBudgetMonth(budgetID: "group-1"))
        #expect(cached.month != before.month)
        #expect(cached.month.categoryGroups.first?.categories.first?.balance == 600)
        let session = ShortcutsBudgetSession(appState: try fixtures.makeAppState(for: bundle))
        _ = try await session.budgetSummary(month: "2026-07")
        #expect(store.cachedBudgetMonth(budgetID: "group-1")?.selectedMonth == "2026-08")
        store.reset()
        #expect(try await store.openCachedBudget(bundle.budget))
        let future = try await session.loadedMonth(preferred: "2029-12")
        #expect(future.availableMonths.contains("2029-12"))
        #expect(future.isTrackingBudget)
    }

    @Test func partialGridConversionDropsOnlyStaleIdentityAndPreservesSameModeFailures() async throws {
        let repository = BudgetViewportTestRepository()
        let first = TrackingBudgetPresentationTests.loaded(try TrackingBudgetPresentationTests.month("2026-07"))
        let second = TrackingBudgetPresentationTests.loaded(try TrackingBudgetPresentationTests.month("2026-08"))
        await repository.set(first)
        await repository.set(second)
        let viewport = BudgetViewportModel(repository: repository)
        viewport.setResolvedMonthCount(2)
        await viewport.load(budgetID: "fixture", anchorMonth: "2026-07")
        await repository.setError(ViewportTestError.unsupported, for: "2026-08")
        _ = await viewport.refreshVisibleMonths()
        #expect(viewport.monthSnapshots.count == 2)
        var converted = BudgetViewportFixtures.loaded("2026-07")
        converted.modeIdentity = .init(storageID: "demo", table: .envelope, revision: "new")
        await repository.set(converted)
        _ = await viewport.refreshVisibleMonths()
        #expect(viewport.monthSnapshots.count == 1)
        #expect(viewport.monthSnapshots["2026-08"] == nil)
        #expect(viewport.monthErrors["2026-08"] != nil)
        viewport.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        #expect(viewport.assignmentWorkflow.isPresented)
        // Conversion can arrive after the last month read but before publication.
        await repository.setModeIdentity(first.modeIdentity)
        #expect(await viewport.refreshVisibleMonths() == false)
        #expect(viewport.monthSnapshots.isEmpty)
        #expect(!viewport.assignmentWorkflow.isPresented)
        #expect(viewport.monthErrors["2026-07"] != nil)
    }

    @Test func monthBoundaryAndForegroundRefreshNeedNoNetwork() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let transport = RecordingSyncTransport()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(syncTransportFactory: { _ in transport }, additionalFixtureSQL: Self.sql)
        let state = try fixtures.makeAppState(for: bundle)
        var clock = date("2026-07")
        var publications = 0
        let coordinator = BudgetCalendarCoordinator(now: { clock }, publishWidgets: { publications += 1 })
        coordinator.configure(appState: state)
        await coordinator.refresh(force: true)
        let before = state.localDataRevision
        clock = date("2026-08")
        await coordinator.refresh()
        #expect(coordinator.currentMonth == "2026-08")
        #expect(state.localDataRevision == before + 1)
        #expect(publications == 2)
        await coordinator.refresh()
        #expect(publications == 2)
        await coordinator.refresh(force: true)
        #expect(publications == 3)
        #expect(await transport.messageCounts().isEmpty)
        let loaded = try await bundle.store.readBudgetMonth(budgetID: "group-1", month: "2026-07", now: clock)
        #expect(BudgetSummaryEntity.make(from: loaded, currentMonth: coordinator.currentMonth!).savingsLabel == "Overspent")
    }

    @Test func calendarPolicyCoversLocalYearAndLeapMonthBoundaries() {
        for month in ["2024-02", "2026-12"] {
            let start = date(month)
            let boundary = WidgetMonthID.nextBoundary(after: start, graceInterval: 0)
            #expect(WidgetMonthID.current(now: boundary) == (month == "2024-02" ? "2024-03" : "2027-01"))
            #expect(WidgetMonthID.current(now: boundary.addingTimeInterval(-1)) == month)
        }
        let instant = ISO8601DateFormatter().date(from: "2027-01-01T01:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(WidgetMonthID.current(now: instant, calendar: calendar) == "2027-01")
        calendar.timeZone = TimeZone(secondsFromGMT: -18000)!
        #expect(WidgetMonthID.current(now: instant, calendar: calendar) == "2026-12")
    }

    private func date(_ month: String) -> Date {
        ReportCalendar.date(fromMonthID: month, calendar: ReportCalendar.gregorianLocal)!
    }
    private func conversion(_ type: String, index: Int) -> ActualSyncDecodedMessage {
        .init(timestamp: "2026-09-08T00:00:00.000Z-000\(index)-0000000000000001", dataset: "preferences", row: "budgetType", column: "value", serializedValue: "S:\(type)")
    }
}
