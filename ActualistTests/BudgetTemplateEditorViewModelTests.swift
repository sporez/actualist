import Foundation
import Testing
@testable import Actualist

@Suite("Budget template editor view model")
@MainActor
struct BudgetTemplateEditorViewModelTests {
    private let now = Calendar(identifier: .gregorian).date(
        from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
    )!
    private let target = BudgetTemplateEditorTarget(
        categoryID: "groceries",
        categoryName: "Groceries",
        month: "2026-09"
    )

    @Test func loadEditableDraftsAndSaveWithoutApplying() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(viewModel.phase == .ready)
        #expect(viewModel.isEditable)
        #expect(viewModel.canSave)
        #expect(viewModel.navigationTitle == "Edit Templates")
        #expect(viewModel.items.map(\.draft) == [.monthlyFixed(amount: 400, now: now)])

        viewModel.setAmount("250", id: try #require(viewModel.items.first?.id))
        let saved = await viewModel.save()
        #expect(saved)
        let drafts = await repository.savedDrafts()
        #expect(drafts == [[.monthlyFixed(amount: 250, now: now)]])
    }

    @Test func readOnlyRefusesMutationsAndSave() async throws {
        let repository = EditorTemplateRepository(
            snapshot: BudgetTemplateEditorSnapshot(
                categoryID: "groceries",
                categoryName: "Groceries",
                drafts: [.monthlyFixed(amount: 400, now: now)],
                lock: .readOnly(.noteManaged),
                schedules: [],
                currency: .usd,
                hasDefinition: true
            )
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(!viewModel.isEditable)
        #expect(!viewModel.canSave)
        #expect(viewModel.navigationTitle == "View Templates")
        viewModel.add(.remainder)
        #expect(viewModel.items.count == 1)
        #expect(await viewModel.save() == false)
        #expect(await repository.savedDrafts().isEmpty)
    }

    @Test func addRemoveAndSingletonKinds() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")

        #expect(viewModel.navigationTitle == "Add Template")
        viewModel.add(.monthlyFixed)
        viewModel.add(.remainder)
        viewModel.add(.remainder)
        #expect(viewModel.items.map(\.draft.kind) == [.monthlyFixed, .remainder])
        #expect(!viewModel.addableKinds.contains(.remainder))
        viewModel.remove(id: try #require(viewModel.items.last?.id))
        #expect(viewModel.items.map(\.draft.kind) == [.monthlyFixed])
        #expect(viewModel.addableKinds.contains(.remainder))
    }

    @Test func incompleteScheduleCannotSave() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        viewModel.add(.schedule)
        #expect(!viewModel.canSave)
        viewModel.setSchedule(
            BudgetTemplateScheduleOption(id: "rent", name: "Rent"),
            id: try #require(viewModel.items.first?.id)
        )
        #expect(viewModel.canSave)
    }

    @Test func dryRunFollowsCurrentDrafts() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        try await waitUntil { viewModel.dryRun?.budgeted == 40_000 }
        #expect(viewModel.dryRun?.perTemplate == [40_000])

        viewModel.setAmount("100", id: try #require(viewModel.items.first?.id))
        try await waitUntil { viewModel.dryRun?.budgeted == 10_000 }
        #expect(viewModel.dryRun?.perTemplate == [10_000])
    }

    @Test func emptyListSaves() async throws {
        let repository = EditorTemplateRepository(
            snapshot: editableSnapshot(drafts: [.monthlyFixed(amount: 400, now: now)])
        )
        let viewModel = makeViewModel()
        await viewModel.load(repository: repository, budgetID: "budget-1")
        viewModel.remove(id: try #require(viewModel.items.first?.id))
        #expect(viewModel.canSave)
        #expect(await viewModel.save())
        #expect(await repository.savedDrafts() == [[]])
    }

    private func makeViewModel() -> BudgetTemplateEditorViewModel {
        BudgetTemplateEditorViewModel(target: target, now: now, dryRunDelay: .zero)
    }

    private func editableSnapshot(drafts: [BudgetTemplateDraft]) -> BudgetTemplateEditorSnapshot {
        BudgetTemplateEditorSnapshot(
            categoryID: "groceries",
            categoryName: "Groceries",
            drafts: drafts,
            lock: .editable,
            schedules: [BudgetTemplateScheduleOption(id: "rent", name: "Rent")],
            currency: .usd,
            hasDefinition: !drafts.isEmpty
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for editor state")
    }
}

private actor EditorTemplateRepository: BudgetRepositoryProtocol {
    var snapshot: BudgetTemplateEditorSnapshot
    private var saved: [[BudgetTemplateDraft]] = []

    init(snapshot: BudgetTemplateEditorSnapshot) {
        self.snapshot = snapshot
    }

    func savedDrafts() -> [[BudgetTemplateDraft]] { saved }

    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot {
        snapshot
    }

    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun {
        let perTemplate = drafts.map { draft -> Int in
            switch draft {
            case .monthlyFixed(let value):
                return BudgetCurrency.usd.minorUnits(fromDisplay: value.amount) ?? 0
            case .goal(let value):
                return BudgetCurrency.usd.minorUnits(fromDisplay: value.amount) ?? 0
            default:
                return 0
            }
        }
        return BudgetTemplateCategoryDryRun(
            budgeted: perTemplate.reduce(0, +),
            perTemplate: perTemplate
        )
    }

    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        saved.append(drafts)
        return Self.dummyMonth
    }

    func budgets() async throws -> [ActualBudget] { [] }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setAllExpenseCategoryCarryoverAndRefresh(
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }

    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }

    func budgetActionUndoPreview(
        actionID: String,
        budgetID: String
    ) async throws -> BudgetActionUndoPreview {
        BudgetActionUndoPreview(actionID: actionID, month: "", entries: [], block: nil)
    }

    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {}

    private static let dummyMonth = LoadedBudgetMonth(
        availableMonths: ["2026-09"],
        selectedMonth: "2026-09",
        month: try! JSONDecoder().decode(BudgetMonth.self, from: Data(#"""
            {
              "month": "2026-09",
              "incomeAvailable": 0,
              "lastMonthOverspent": 0,
              "forNextMonth": 0,
              "totalBudgeted": 0,
              "toBudget": 0,
              "fromLastMonth": 0,
              "totalIncome": 0,
              "totalSpent": 0,
              "totalBalance": 0,
              "categoryGroups": []
            }
            """#.utf8)),
        alerts: []
    )
}
