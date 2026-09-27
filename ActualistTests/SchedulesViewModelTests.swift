import Foundation
import Testing
@testable import Actualist

@MainActor
@Suite("Schedules view model")
struct SchedulesViewModelTests {
    @Test func cachedFirstRenderThenRefreshes() async {
        let cached = snapshot(budgetID: "budget", ids: ["cached"])
        let refreshed = snapshot(budgetID: "budget", ids: ["fresh"])
        let entered = TestLatch()
        let release = TestLatch()
        let repository = ScheduleRepositoryFake(
            cached: ["budget": cached],
            results: ["budget": .success(refreshed)],
            entered: ["budget": entered],
            release: ["budget": release]
        )
        let context = context()
        let model = SchedulesViewModel(context: context)

        let task = Task {
            await model.load(context: context, repository: repository)
        }
        await entered.wait()

        #expect(model.snapshot?.schedules.map(\.id) == ["cached"])
        #expect(model.isRefreshing)
        #expect(!model.isLoading)

        release.trip()
        await task.value
        #expect(model.snapshot?.schedules.map(\.id) == ["fresh"])
        #expect(!model.isRefreshing)
    }

    @Test func normalizedSearchAndCompletedDisclosureUseOneSnapshot() async {
        let repository = ScheduleRepositoryFake(cached: [
            "budget": snapshot(
                budgetID: "budget",
                schedules: [
                    summary(id: "cafe", name: "Café", status: .upcoming),
                    summary(id: "done", name: "Old bill", status: .completed)
                ]
            )
        ])
        let context = context()
        let model = SchedulesViewModel(context: context)
        await model.load(context: context, repository: repository)

        #expect(model.sections.flatMap(\.rows).map(\.id) == ["cafe"])
        model.searchText = "CAFE"
        #expect(model.sections.flatMap(\.rows).map(\.id) == ["cafe"])
        model.searchText = ""
        model.showsCompleted = true
        #expect(Set(model.sections.flatMap(\.rows).map(\.id)) == ["cafe", "done"])
    }

    @Test func searchUsesThePreparedDisplayedAmountLabel() async {
        let currency = BudgetCurrency.none
        let amount = ScheduleAmount.exact(-12_500)
        let repository = ScheduleRepositoryFake(cached: [
            "budget": snapshot(
                budgetID: "budget",
                schedules: [summary(id: "rent", name: "Rent", amount: amount, status: .upcoming)]
            )
        ])
        let context = context(currency: currency)
        let model = SchedulesViewModel(context: context)
        await model.load(context: context, repository: repository)

        model.searchText = SchedulePresentation.amountLabel(
            amount,
            currency: currency,
            privacyEnabled: false,
            seed: "schedule-rent"
        )
        #expect(model.sections.flatMap(\.rows).map(\.id) == ["rent"])
    }

    @Test func emptyAndErrorStatesDoNotDiscardCachedData() async {
        let cached = snapshot(budgetID: "budget", ids: ["kept"])
        let repository = ScheduleRepositoryFake(
            cached: ["budget": cached],
            results: ["budget": .failure(ScheduleTestError.failed)]
        )
        let context = context()
        let model = SchedulesViewModel(context: context)
        await model.load(context: context, repository: repository)

        #expect(model.snapshot == cached)
        #expect(model.errorMessage != nil)
        #expect(!model.isEmpty)
    }

    @Test func budgetSwitchRejectsStaleCompletion() async {
        let oldEntered = TestLatch()
        let oldRelease = TestLatch()
        let newEntered = TestLatch()
        let newRelease = TestLatch()
        let repository = ScheduleRepositoryFake(
            results: [
                "old": .success(snapshot(budgetID: "old", ids: ["old-row"])),
                "new": .success(snapshot(budgetID: "new", ids: ["new-row"]))
            ],
            entered: ["old": oldEntered, "new": newEntered],
            release: ["old": oldRelease, "new": newRelease]
        )
        let oldContext = context(budgetID: "old")
        let newContext = context(budgetID: "new")
        let model = SchedulesViewModel(context: oldContext)

        let oldTask = Task {
            await model.load(context: oldContext, repository: repository)
        }
        await oldEntered.wait()
        let newTask = Task {
            await model.load(context: newContext, repository: repository)
        }
        await newEntered.wait()
        newRelease.trip()
        await newTask.value
        oldRelease.trip()
        await oldTask.value

        #expect(model.budgetID == "new")
        #expect(model.snapshot?.schedules.map(\.id) == ["new-row"])
    }

    @Test func explicitCancellationRejectsLateResult() async {
        let entered = TestLatch()
        let release = TestLatch()
        let repository = ScheduleRepositoryFake(
            results: ["budget": .success(snapshot(budgetID: "budget", ids: ["late"]))],
            entered: ["budget": entered],
            release: ["budget": release]
        )
        let context = context()
        let model = SchedulesViewModel(context: context)
        let task = Task {
            await model.load(context: context, repository: repository)
        }
        await entered.wait()
        model.cancelLoad()
        release.trip()
        await task.value

        #expect(model.snapshot == nil)
        #expect(!model.isLoading)
        #expect(!model.isRefreshing)
    }

    @Test func taskCancellationRejectsLateResultFromCancellationIgnoringRepository() async {
        let entered = TestLatch()
        let release = TestLatch()
        let repository = ScheduleRepositoryFake(
            results: ["budget": .success(snapshot(budgetID: "budget", ids: ["late"]))],
            entered: ["budget": entered],
            release: ["budget": release]
        )
        let context = context()
        let model = SchedulesViewModel(context: context)
        let task = Task {
            await model.load(context: context, repository: repository)
        }
        await entered.wait()

        task.cancel()
        release.trip()
        await task.value

        #expect(model.snapshot == nil)
        #expect(!model.isLoading)
        #expect(!model.isRefreshing)
    }

    @Test func preCancelledLoadReleasedAfterValidRefreshStartsCannotSupersedeIt() async {
        let obsoleteMayEnter = TestLatch()
        let validEntered = TestLatch()
        let validRelease = TestLatch()
        let repository = ScheduleRepositoryFake(
            results: [
                "old": .success(snapshot(budgetID: "old", ids: ["obsolete"])),
                "new": .success(snapshot(budgetID: "new", ids: ["fresh"]))
            ],
            entered: ["new": validEntered],
            release: ["new": validRelease]
        )
        let oldContext = context(budgetID: "old")
        let newContext = context(budgetID: "new")
        let model = SchedulesViewModel(context: oldContext)
        let obsolete = Task {
            await obsoleteMayEnter.wait()
            await model.load(context: oldContext, repository: repository)
        }
        obsolete.cancel()

        let valid = Task {
            defer { validEntered.trip() }
            await model.load(context: newContext, repository: repository)
        }
        await withTaskCancellationHandler {
            await validEntered.wait()
        } onCancel: {
            validEntered.trip()
            obsoleteMayEnter.trip()
            validRelease.trip()
        }
        #expect(model.loadedIdentity == newContext.identity)
        #expect(model.isLoading)
        if Task.isCancelled { valid.cancel() }
        obsoleteMayEnter.trip()
        await obsolete.value
        validRelease.trip()
        await valid.value

        #expect(model.loadedIdentity == newContext.identity)
        #expect(model.snapshot?.schedules.map(\.id) == ["fresh"])
        #expect(!model.isLoading)
        #expect(!model.isRefreshing)
    }

    @Test func statusGroupsStayDistinctAndCompletedRemainsCollapsed() async {
        let schedules = ScheduleStatus.allCases.map {
            summary(id: $0.rawValue, name: $0.rawValue, status: $0)
        }
        let repository = ScheduleRepositoryFake(cached: [
            "budget": snapshot(budgetID: "budget", schedules: schedules)
        ])
        let context = context()
        let model = SchedulesViewModel(context: context)
        await model.load(context: context, repository: repository)

        #expect(model.sections.map(\.kind) == [.missed, .due, .upcoming, .paid, .later])
        model.showsCompleted = true
        #expect(model.sections.map(\.kind) == [.missed, .due, .upcoming, .paid, .later, .completed])
    }

    @Test func displayContextChangeClearsSearchAndReprojectsPrivacyAndCurrency() async {
        let repository = ScheduleRepositoryFake(cached: [
            "budget": snapshot(
                budgetID: "budget",
                schedules: [summary(id: "rent", name: "Real Rent", amount: .exact(-12_500), status: .due)]
            )
        ])
        let visibleContext = context(currency: .usd)
        let model = SchedulesViewModel(context: visibleContext)
        await model.load(context: visibleContext, repository: repository)
        model.searchText = "Real Rent"

        let privateContext = context(currency: .jpy, privacyModeEnabled: true)
        await model.load(context: privateContext, repository: repository)
        let row = model.sections.first?.rows.first

        #expect(model.searchText.isEmpty)
        #expect(row?.title.hasPrefix("Sample Schedule ") == true)
        #expect(row?.title != "Real Rent")
        #expect(row?.referenceText != "No payee • Checking")
        #expect(row?.amountText != BudgetCurrency.usd.formatted(-12_500))
    }

    @Test func sessionGenerationChangeClearsPriorSnapshotBeforeRefreshCompletes() async {
        let originalRepository = ScheduleRepositoryFake(cached: [
            "budget": snapshot(budgetID: "budget", ids: ["old"])
        ])
        let originalContext = context(sessionGeneration: 1)
        let model = SchedulesViewModel(context: originalContext)
        await model.load(context: originalContext, repository: originalRepository)

        let entered = TestLatch()
        let release = TestLatch()
        let nextRepository = ScheduleRepositoryFake(
            cached: ["budget": snapshot(budgetID: "budget", ids: ["stale-cache"])],
            results: ["budget": .success(snapshot(budgetID: "budget", ids: ["new"]))],
            entered: ["budget": entered],
            release: ["budget": release]
        )
        let nextContext = context(sessionGeneration: 2)
        let task = Task {
            await model.load(context: nextContext, repository: nextRepository)
        }
        await entered.wait()

        #expect(model.snapshot == nil)
        #expect(model.isLoading)

        release.trip()
        await task.value
        #expect(model.snapshot?.schedules.map(\.id) == ["new"])
    }

    @Test func sameContextRefreshRetainsSearchAndCompletedDisclosure() async {
        let context = context()
        let model = SchedulesViewModel(context: context)
        let originalRepository = ScheduleRepositoryFake(cached: [
            "budget": snapshot(
                budgetID: "budget",
                schedules: [summary(id: "done", name: "Old bill", status: .completed)]
            )
        ])
        await model.load(context: context, repository: originalRepository)
        model.searchText = "Old bill"
        model.showsCompleted = true

        let refreshedRepository = ScheduleRepositoryFake(results: [
            "budget": .success(snapshot(budgetID: "budget", ids: ["fresh"]))
        ])
        await model.load(context: context, repository: refreshedRepository)

        #expect(model.searchText == "Old bill")
        #expect(model.showsCompleted)
        #expect(model.snapshot?.schedules.map(\.id) == ["fresh"])
    }

    private func snapshot(budgetID: String, ids: [String]) -> LoadedSchedules {
        snapshot(budgetID: budgetID, schedules: ids.map { summary(id: $0, name: $0, status: .upcoming) })
    }

    private func snapshot(budgetID: String, schedules: [ScheduleSummary]) -> LoadedSchedules {
        LoadedSchedules(
            budgetID: budgetID,
            schedules: schedules,
            detailsByID: [:],
            defaultUpcomingLength: "7"
        )
    }

    private func summary(
        id: String,
        name: String,
        amount: ScheduleAmount = .exact(-100),
        status: ScheduleStatus
    ) -> ScheduleSummary {
        ScheduleSummary(
            id: id,
            name: name,
            amount: amount,
            account: ScheduleAccountReference(id: "account", name: "Checking", availability: .available),
            payee: SchedulePayeeReference(id: nil, name: nil, isMissing: false),
            effectiveNextDate: "2026-09-28",
            status: status,
            postsTransaction: false,
            sortOrder: nil,
            unsupportedReasons: []
        )
    }

    private func context(
        budgetID: String = "budget",
        sessionGeneration: Int = 1,
        currency: BudgetCurrency = .usd,
        privacyModeEnabled: Bool = false
    ) -> SchedulesViewContext {
        SchedulesViewContext(
            identity: SchedulesBudgetIdentity(
                budgetID: budgetID,
                sessionGeneration: sessionGeneration
            ),
            currency: currency,
            isPrivacyModeEnabled: privacyModeEnabled,
            asOfDayID: "2026-09-27"
        )
    }
}

@MainActor
private final class ScheduleRepositoryFake: ScheduleRepositoryProtocol {
    private let cached: [String: LoadedSchedules]
    private let results: [String: Result<LoadedSchedules, Error>]
    private let entered: [String: TestLatch]
    private let release: [String: TestLatch]

    init(
        cached: [String: LoadedSchedules] = [:],
        results: [String: Result<LoadedSchedules, Error>] = [:],
        entered: [String: TestLatch] = [:],
        release: [String: TestLatch] = [:]
    ) {
        self.cached = cached
        self.results = results
        self.entered = entered
        self.release = release
    }

    func cachedSchedules(budgetID: String) -> LoadedSchedules? {
        cached[budgetID]
    }

    func refreshSchedules(budgetID: String, asOf today: String) async throws -> LoadedSchedules {
        entered[budgetID]?.trip()
        if let release = release[budgetID] {
            await release.wait()
        }
        if let result = results[budgetID] {
            return try result.get()
        }
        return cached[budgetID] ?? .empty(budgetID: budgetID)
    }
}

private enum ScheduleTestError: Error {
    case failed
}
