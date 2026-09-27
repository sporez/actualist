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
        let model = SchedulesViewModel()

        let task = Task {
            await model.load(budgetID: "budget", repository: repository, today: "2026-09-27")
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
        let model = SchedulesViewModel()
        await model.load(budgetID: "budget", repository: repository, today: "2026-09-27")

        #expect(model.sections.flatMap(\.schedules).map(\.id) == ["cafe"])
        model.searchText = "CAFE"
        #expect(model.sections.flatMap(\.schedules).map(\.id) == ["cafe"])
        model.searchText = ""
        model.showsCompleted = true
        #expect(Set(model.sections.flatMap(\.schedules).map(\.id)) == ["cafe", "done"])
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
        let model = SchedulesViewModel(currency: currency)
        await model.load(budgetID: "budget", repository: repository, today: "2026-09-27")

        model.searchText = SchedulePresentation.amountLabel(amount, currency: currency)
        #expect(model.sections.flatMap(\.schedules).map(\.id) == ["rent"])
    }

    @Test func emptyAndErrorStatesDoNotDiscardCachedData() async {
        let cached = snapshot(budgetID: "budget", ids: ["kept"])
        let repository = ScheduleRepositoryFake(
            cached: ["budget": cached],
            results: ["budget": .failure(ScheduleTestError.failed)]
        )
        let model = SchedulesViewModel()
        await model.load(budgetID: "budget", repository: repository, today: "2026-09-27")

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
        let model = SchedulesViewModel()

        let oldTask = Task {
            await model.load(budgetID: "old", repository: repository, today: "2026-09-27")
        }
        await oldEntered.wait()
        let newTask = Task {
            await model.load(budgetID: "new", repository: repository, today: "2026-09-27")
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
        let model = SchedulesViewModel()
        let task = Task {
            await model.load(budgetID: "budget", repository: repository, today: "2026-09-27")
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
        let model = SchedulesViewModel()
        let task = Task {
            await model.load(budgetID: "budget", repository: repository, today: "2026-09-27")
        }
        await entered.wait()

        task.cancel()
        release.trip()
        await task.value

        #expect(model.snapshot == nil)
        #expect(!model.isLoading)
        #expect(!model.isRefreshing)
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
