import Foundation
import Testing
@testable import Actualist

@MainActor
struct TrackingBudgetDelayedWorkflowTests {
    private let oldIdentity = BudgetModeIdentity(storageID: "budget", table: .tracking, revision: "r1")
    private let newIdentity = BudgetModeIdentity(storageID: "budget", table: .tracking, revision: "r2")

    @Test func assignmentIgnoresDelayedSuccessFromAnInvalidatedContext() async throws {
        let repository = DelayedWorkflowRepository(result: .success)
        let workflow = BudgetAssignmentWorkflow()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 100)
        workflow.begin(for: category, budgetID: "budget", month: "2026-07", modeIdentity: oldIdentity)
        workflow.replaceInputDigits("125")

        let submission = Task {
            await workflow.submit(selectedMonth: "2026-07", budgetID: "budget", repository: repository)
        }
        await repository.waitForAssignment()

        workflow.invalidate()
        workflow.begin(for: category, budgetID: "budget", month: "2026-07", modeIdentity: newIdentity)
        workflow.replaceInputDigits("175")
        await repository.resume()
        _ = await submission.value

        #expect(workflow.context?.modeIdentity == newIdentity)
        #expect(workflow.draft?.inputDigits == "175")
        #expect(await repository.assignmentExpectedModes == [oldIdentity])
    }

    @Test func assignmentIgnoresDelayedFailureFromAnInvalidatedContext() async throws {
        let repository = DelayedWorkflowRepository(result: .failure)
        let workflow = BudgetAssignmentWorkflow()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 100)
        workflow.begin(for: category, budgetID: "budget", month: "2026-07", modeIdentity: oldIdentity)
        workflow.replaceInputDigits("125")

        let submission = Task {
            await workflow.submit(selectedMonth: "2026-07", budgetID: "budget", repository: repository)
        }
        await repository.waitForAssignment()

        workflow.invalidate()
        workflow.begin(for: category, budgetID: "budget", month: "2026-07", modeIdentity: newIdentity)
        workflow.replaceInputDigits("175")
        await repository.resume()
        _ = await submission.value

        #expect(workflow.context?.modeIdentity == newIdentity)
        #expect(workflow.draft?.inputDigits == "175")
        #expect(workflow.errorMessage == nil)
    }

    @Test func moveIgnoresDelayedSuccessFromAnInvalidatedContext() async throws {
        let repository = DelayedWorkflowRepository(result: .success)
        let workflow = BudgetMoveMoneyWorkflow()
        let category = try BudgetViewModelFixtures.decodeCategory(budgeted: 100)
        workflow.begin(for: category, budgetID: "budget", month: "2026-07", modeIdentity: oldIdentity)
        workflow.selectDestination(.category(id: "dining", name: "Dining"))
        workflow.setAmountDollars(1, currency: .usd)

        let submission = Task {
            await workflow.submit(selectedMonth: "2026-07", budgetID: "budget", repository: repository)
        }
        await repository.waitForMove()

        workflow.invalidate()
        workflow.begin(for: category, budgetID: "budget", month: "2026-07", modeIdentity: newIdentity)
        workflow.selectDestination(.category(id: "dining", name: "Dining"))
        workflow.setAmountDollars(2, currency: .usd)
        await repository.resume()
        _ = await submission.value

        #expect(workflow.context?.modeIdentity == newIdentity)
        #expect(workflow.displayAmount == 200)
        #expect(await repository.moveExpectedModes == [oldIdentity])
    }

    @Test func oldTemplateFailureCannotReplaceANewSubmission() async {
        let oldRepository = DelayedWorkflowRepository(result: .failure)
        let newRepository = DelayedWorkflowRepository(result: .success)
        let workflow = BudgetTemplateWorkflow()
        let old = Task {
            await workflow.apply(command: .overwrite, selectedMonth: "2026-07", budgetID: "budget",
                expectedMode: oldIdentity, repository: oldRepository)
        }
        await oldRepository.waitForAssignment()
        workflow.noteSelectionChange()
        let current = Task {
            await workflow.apply(command: .overwrite, selectedMonth: "2026-07", budgetID: "budget",
                expectedMode: newIdentity, repository: newRepository)
        }
        await newRepository.waitForAssignment()
        await oldRepository.resume()
        _ = await old.value
        #expect(workflow.isApplying)
        await newRepository.resume()
        _ = await current.value
        #expect(workflow.submissionState == .draft)
        #expect(await newRepository.assignmentExpectedModes == [newIdentity])
    }

}

private actor DelayedWorkflowRepository: BudgetRepositoryProtocol {
    enum Result { case success, failure }

    private let result: Result
    private var assignmentWaiter: CheckedContinuation<Void, Never>?
    private var moveWaiter: CheckedContinuation<Void, Never>?
    private var assignmentStarted = false
    private var moveStarted = false
    private var completion: CheckedContinuation<Void, Never>?
    private var resumeRequested = false
    private(set) var assignmentExpectedModes: [BudgetModeIdentity?] = []
    private(set) var moveExpectedModes: [BudgetModeIdentity?] = []

    init(result: Result) { self.result = result }

    func waitForAssignment() async {
        if assignmentStarted { return }
        await withCheckedContinuation { assignmentWaiter = $0 }
    }

    func waitForMove() async {
        if moveStarted { return }
        await withCheckedContinuation { moveWaiter = $0 }
    }

    func resume() {
        if let completion {
            completion.resume()
            self.completion = nil
        } else {
            resumeRequested = true
        }
    }

    func budgets() async throws -> [ActualBudget] { [] }
    func currentBudgetMonth(budgetID: String, preferredMonth: String) async throws -> LoadedBudgetMonth { loaded() }
    func budgetMonth(budgetID: String, selectedMonth: String) async throws -> LoadedBudgetMonth { loaded() }

    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity?, categoryID: String, budgeted: Int, budgetID: String, month: String, didAssign: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth {
        assignmentExpectedModes.append(expectedMode)
        assignmentStarted = true
        assignmentWaiter?.resume(); assignmentWaiter = nil
        await waitForCompletion()
        if case .failure = result { throw LocalFirstError.invalidLocalWrite("delayed assignment failed") }
        return loaded(modeIdentity: expectedMode)
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity?, command: BudgetMoveMoneyCommand, budgetID: String, month: String, didMove: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(expectedMode: expectedMode, commands: [command], budgetID: budgetID, month: month, didMove: didMove)
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity?, commands: [BudgetMoveMoneyCommand], budgetID: String, month: String, didMove: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth {
        moveExpectedModes.append(expectedMode)
        moveStarted = true
        moveWaiter?.resume(); moveWaiter = nil
        await waitForCompletion()
        if case .failure = result { throw LocalFirstError.invalidLocalWrite("delayed move failed") }
        return loaded(modeIdentity: expectedMode)
    }

    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity?, categoryID: String, carryover: Bool, budgetID: String, startMonth: String, didSetCarryover: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { loaded(modeIdentity: expectedMode) }
    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity?, carryover: Bool, budgetID: String, startMonth: String) async throws -> LoadedBudgetMonth { loaded(modeIdentity: expectedMode) }
    func setCategoryHiddenAndRefresh(categoryID: String, hidden: Bool, budgetID: String, month: String, didUpdate: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { loaded() }
    func setCategoryGroupHiddenAndRefresh(groupID: String, hidden: Bool, budgetID: String, month: String, didUpdate: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { loaded() }
    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity?, command: BudgetTemplateCommand, budgetID: String, month: String, didApply: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth {
        try await assignCategoryBudgetAndRefresh(expectedMode: expectedMode, categoryID: "fixture", budgeted: 0,
            budgetID: budgetID, month: month, didAssign: didApply)
    }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview {
        throw LocalFirstError.unsupportedWrite
    }
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {
        throw LocalFirstError.unsupportedWrite
    }

    private func waitForCompletion() async {
        if resumeRequested {
            resumeRequested = false
            return
        }
        await withCheckedContinuation { completion = $0 }
    }

    private func loaded(modeIdentity: BudgetModeIdentity? = nil) -> LoadedBudgetMonth {
        LoadedBudgetMonth(modeIdentity: modeIdentity, availableMonths: ["2026-07"], selectedMonth: "2026-07", month: try! BudgetViewModelFixtures.decodeBudgetMonth(visibleCategoryBalance: 100, hiddenCategoryBalance: 0, lastMonthOverspent: 0), alerts: [])
    }
}
