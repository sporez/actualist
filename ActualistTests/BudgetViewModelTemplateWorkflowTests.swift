import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetViewModelTemplateWorkflowTests {
    // MARK: - Same-context application

    @Test func sameMonthTemplateResultAppliesNormally() async throws {
        let repo = ControllableTemplateRepository()
        let model = BudgetViewModel()
        await model.selectMonth("2026-08", budgetID: "budget", repository: repo)
        #expect(model.selectedMonth == "2026-08")

        let applyTask = Task { @MainActor in
            await model.applyMonthTemplate(.overwrite, budgetID: "budget", repository: repo)
        }
        await repo.waitForApplySuspended()

        // No navigation happens; resume with the August refresh.
        await repo.resumeApply(returningMonth: "2026-08")

        let result = await applyTask.value
        #expect(result == true)
        #expect(model.selectedMonth == "2026-08")
        #expect(model.budgetMonth?.month == "2026-08")
        #expect(model.errorMessage == nil)
        #expect(model.monthTemplateSubmissionState == .draft)

        let template = try await repo.onlyTemplate()
        #expect(template.budgetID == "budget")
        #expect(template.month == "2026-08")
    }

    // MARK: - Stale result after month switch

    @Test func augustTemplateResultDoesNotReplaceSeptemberAfterMonthSwitch() async throws {
        let repo = ControllableTemplateRepository()
        let model = BudgetViewModel()
        await model.selectMonth("2026-08", budgetID: "budget", repository: repo)
        #expect(model.selectedMonth == "2026-08")

        let applyTask = Task { @MainActor in
            await model.applyMonthTemplate(.overwrite, budgetID: "budget", repository: repo)
        }
        await repo.waitForApplySuspended()

        // User switches to September while the August apply is still in flight.
        await model.selectMonth("2026-09", budgetID: "budget", repository: repo)
        #expect(model.selectedMonth == "2026-09")
        #expect(model.budgetMonth?.month == "2026-09")

        // The August write already targeted August; resume its refresh.
        await repo.resumeApply(returningMonth: "2026-08")

        let result = await applyTask.value
        // Stale result dropped: the UI stays on September.
        #expect(result == false)
        #expect(model.selectedMonth == "2026-09")
        #expect(model.budgetMonth?.month == "2026-09")
        #expect(model.errorMessage == nil)
        #expect(model.monthTemplateSubmissionState == .draft)

        // The August mutation was still submitted to the repository.
        let template = try await repo.onlyTemplate()
        #expect(template.month == "2026-08")
    }

    @Test func staleTemplateResultAfterRoundTripBackToSameMonthIsStillDropped() async throws {
        // Aug -> Sep -> Aug: the month matches the stale request again, but a
        // fresh load superseded it. The generation guard must still drop the
        // stale August refresh so it cannot overwrite the fresh reload.
        let repo = ControllableTemplateRepository()
        let model = BudgetViewModel()
        await model.selectMonth("2026-08", budgetID: "budget", repository: repo)

        let applyTask = Task { @MainActor in
            await model.applyMonthTemplate(.overwrite, budgetID: "budget", repository: repo)
        }
        await repo.waitForApplySuspended()

        await model.selectMonth("2026-09", budgetID: "budget", repository: repo)
        await model.selectMonth("2026-08", budgetID: "budget", repository: repo)
        #expect(model.selectedMonth == "2026-08")
        #expect(model.budgetMonth?.month == "2026-08")

        await repo.resumeApply(returningMonth: "2026-08")

        let result = await applyTask.value
        #expect(result == false)
        #expect(model.selectedMonth == "2026-08")
        // The fresh August reload (from re-navigating) must remain in place;
        // its toBudget marker distinguishes it from the stale refresh.
        #expect(model.budgetMonth?.toBudget == ControllableTemplateRepository.freshMarker)
    }

    // MARK: - Stale result after budget switch

    @Test func staleResultFromBudgetADoesNotReplaceBudgetB() async throws {
        let repo = ControllableTemplateRepository()
        let model = BudgetViewModel()
        await model.selectMonth("2026-08", budgetID: "budget-a", repository: repo)
        #expect(model.selectedMonth == "2026-08")

        let applyTask = Task { @MainActor in
            await model.applyMonthTemplate(.overwrite, budgetID: "budget-a", repository: repo)
        }
        await repo.waitForApplySuspended()

        // Switch to a different budget (and month) while budget A's apply runs.
        await model.selectMonth("2026-07", budgetID: "budget-b", repository: repo)
        #expect(model.selectedMonth == "2026-07")
        #expect(model.budgetMonth?.month == "2026-07")

        await repo.resumeApply(returningMonth: "2026-08")

        let result = await applyTask.value
        #expect(result == false)
        #expect(model.selectedMonth == "2026-07")
        #expect(model.budgetMonth?.month == "2026-07")
        #expect(model.errorMessage == nil)
        #expect(model.monthTemplateSubmissionState == .draft)

        let template = try await repo.onlyTemplate()
        #expect(template.budgetID == "budget-a")
        #expect(template.month == "2026-08")
    }

    // MARK: - Stale failure

    @Test func staleTemplateFailureDoesNotOverwriteANewerContextError() async throws {
        let repo = ControllableTemplateRepository()
        let model = BudgetViewModel()
        await model.selectMonth("2026-08", budgetID: "budget", repository: repo)

        let applyTask = Task { @MainActor in
            await model.applyMonthTemplate(.overwrite, budgetID: "budget", repository: repo)
        }
        await repo.waitForApplySuspended()

        await model.selectMonth("2026-09", budgetID: "budget", repository: repo)
        // Simulate a September-specific error already on screen.
        model.errorMessage = "september-specific error"

        await repo.resumeApply(throwing: TestError("august apply failed"))

        let result = await applyTask.value
        #expect(result == false)
        #expect(model.selectedMonth == "2026-09")
        #expect(model.budgetMonth?.month == "2026-09")
        // The stale August failure must not surface over September's state.
        #expect(model.errorMessage == "september-specific error")
        #expect(model.monthTemplateSubmissionState == .draft)
    }

    // MARK: - No duplicate submission during in-flight request

    @Test func duplicateMonthTemplateSubmissionIsRejectedWhileInFlight() async throws {
        let repo = ControllableTemplateRepository()
        let model = BudgetViewModel()
        await model.selectMonth("2026-08", budgetID: "budget", repository: repo)

        let firstApply = Task { @MainActor in
            await model.applyMonthTemplate(.overwrite, budgetID: "budget", repository: repo)
        }
        await repo.waitForApplySuspended()

        // A second apply while the first is in flight is rejected and records
        // nothing new; the first request keeps ownership of the submission.
        let second = Task { @MainActor in
            await model.applyMonthTemplate(.fillEmpty, budgetID: "budget", repository: repo)
        }
        let secondResult = await second.value
        #expect(secondResult == false)
        #expect(model.isApplyingMonthTemplate)
        let recorded = await repo.templateCount()
        #expect(recorded == 1)

        await repo.resumeApply(returningMonth: "2026-08")
        let firstResult = await firstApply.value
        #expect(firstResult == true)
        #expect(model.selectedMonth == "2026-08")
        #expect(model.monthTemplateSubmissionState == .draft)
    }
}

// MARK: - Controllable repository

/// A `BudgetRepositoryProtocol` fake whose `applyBudgetTemplateAndRefresh` hangs
/// on a continuation until the test resumes it. `budgetMonth`/`currentBudgetMonth`
/// return immediately so the view model can navigate while a template apply is
/// suspended. Each returned `LoadedBudgetMonth` is tagged with its month (and a
/// `toBudget` marker for the fresh-reload round-trip test) so tests can tell
/// which month's data ended up on screen.
private actor ControllableTemplateRepository: BudgetRepositoryProtocol {
    static let freshMarker = 999_999

    private var templates: [RecordedBudgetTemplate] = []
    private var applyContinuation: CheckedContinuation<LoadedBudgetMonth, Error>?
    private var suspendWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspended = false

    func budgets() async throws -> [ActualBudget] { [] }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.makeLoadedMonth(preferredMonth)
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.makeLoadedMonth(selectedMonth, toBudget: Self.freshMarker)
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        templates.append(
            RecordedBudgetTemplate(command: command, budgetID: budgetID, month: month)
        )
        await didApply()
        return try await withCheckedThrowingContinuation { continuation in
            applyContinuation = continuation
            suspended = true
            let waiters = suspendWaiters
            suspendWaiters = []
            waiters.forEach { $0.resume(returning: ()) }
        }
    }

    func resumeApply(returningMonth month: String) {
        let loaded = Self.makeLoadedMonth(month)
        applyContinuation?.resume(returning: loaded)
        applyContinuation = nil
        suspended = false
    }

    func resumeApply(throwing error: Error) {
        applyContinuation?.resume(throwing: error)
        applyContinuation = nil
        suspended = false
    }

    /// Block until an in-flight `applyBudgetTemplateAndRefresh` has recorded its
    /// request and suspended on its continuation, so the test can interleave
    /// navigation before resuming the result.
    func waitForApplySuspended() async {
        if suspended { return }
        await withCheckedContinuation { continuation in
            suspendWaiters.append(continuation)
        }
    }

    func templateCount() -> Int { templates.count }
    func onlyTemplate() throws -> RecordedBudgetTemplate { try #require(templates.first) }

    // MARK: Unused protocol members

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw TestError("not used")
    }

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw TestError("not used")
    }

    func setAllExpenseCategoryCarryoverAndRefresh(
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        throw TestError("not used")
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw TestError("not used")
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw TestError("not used")
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw TestError("not used")
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw TestError("not used")
    }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }

    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }

    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview {
        throw TestError("not used")
    }

    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {
        throw TestError("not used")
    }

    static func makeLoadedMonth(_ month: String, toBudget: Int = 0) -> LoadedBudgetMonth {
        let json = """
        {
          "month": "\(month)",
          "incomeAvailable": 0,
          "lastMonthOverspent": 0,
          "forNextMonth": 0,
          "totalBudgeted": 0,
          "toBudget": \(toBudget),
          "fromLastMonth": 0,
          "totalIncome": 0,
          "totalSpent": 0,
          "totalBalance": 0,
          "categoryGroups": []
        }
        """.data(using: .utf8)!
        let monthModel = try! JSONDecoder().decode(BudgetMonth.self, from: json)
        return LoadedBudgetMonth(
            availableMonths: [month],
            selectedMonth: month,
            month: monthModel,
            alerts: []
        )
    }
}
