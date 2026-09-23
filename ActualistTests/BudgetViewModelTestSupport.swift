import Foundation
import Testing
@testable import Actualist

enum BudgetViewModelFixtures {
    static func decodeBudgetMonth(
        visibleCategoryBalance: Int,
        hiddenCategoryBalance: Int,
        categoryBudgeted: Int = 0,
        categorySpent: Int = 0,
        visibleCategoryCarryover: Bool = false,
        visibleCategoryHasTemplate: Bool = false,
        toBudget: Int = 0,
        counterpartyCategoryBalance: Int? = nil,
        lastMonthOverspent: Int
    ) throws -> BudgetMonth {
        let counterpartyCategoryJSON = counterpartyCategoryBalance.map { balance in
            """
                {
                  "id": "utilities",
                  "name": "🧹 Utilities",
                  "is_income": false,
                  "hidden": false,
                  "group_id": "bills",
                  "budgeted": 0,
                  "spent": 0,
                  "balance": \(balance),
                  "carryover": false
                },
            """
        } ?? ""

        let json = """
        {
          "month": "2026-06",
          "incomeAvailable": 0,
          "lastMonthOverspent": \(lastMonthOverspent),
          "forNextMonth": 0,
          "totalBudgeted": 0,
          "toBudget": \(toBudget),
          "fromLastMonth": 0,
          "totalIncome": 0,
          "totalSpent": 0,
          "totalBalance": 0,
          "categoryGroups": [
            {
              "id": "income",
              "name": "Income",
              "is_income": true,
              "hidden": false,
              "budgeted": 0,
              "spent": 0,
              "balance": 0,
              "categories": []
            },
            {
              "id": "bills",
              "name": "Monthly Bills",
              "is_income": false,
              "hidden": false,
              "budgeted": 0,
              "spent": 0,
              "balance": 0,
              "categories": [
                {
                  "id": "mortgage",
                  "name": "🏡 Mortgage",
                  "is_income": false,
                  "hidden": false,
                  "group_id": "bills",
                  "budgeted": \(categoryBudgeted),
                  "spent": \(categorySpent),
                  "balance": \(visibleCategoryBalance),
                  "carryover": \(visibleCategoryCarryover),
                  "hasTemplateDefinition": \(visibleCategoryHasTemplate)
                },
                \(counterpartyCategoryJSON)
                {
                  "id": "old",
                  "name": "Hidden",
                  "is_income": false,
                  "hidden": true,
                  "group_id": "bills",
                  "budgeted": 0,
                  "spent": 0,
                  "balance": \(hiddenCategoryBalance),
                  "carryover": false
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        return try JSONDecoder().decode(BudgetMonth.self, from: json)
    }

    static func decodeCategory(budgeted: Int) throws -> BudgetMonthCategory {
        let json = """
        {
          "id": "gas",
          "name": "⛽️ Gas",
          "is_income": false,
          "hidden": false,
          "group_id": "bills",
          "budgeted": \(budgeted),
          "spent": 0,
          "balance": 11220,
          "carryover": false
        }
        """.data(using: .utf8)!

        return try JSONDecoder().decode(BudgetMonthCategory.self, from: json)
    }

    static func hiddenActionBudgetMonth() -> BudgetMonth {
        let individuallyHidden = BudgetMonthCategory(
            id: "hidden-category", name: "Hidden Category", isIncome: false,
            hidden: true, groupID: "visible-group", budgeted: 100,
            spent: -20, balance: 80, carryover: false
        )
        let hiddenGroupChild = BudgetMonthCategory(
            id: "hidden-group-child", name: "Hidden Group Child", isIncome: false,
            hidden: false, groupID: "hidden-group", budgeted: 200,
            spent: -30, balance: 170, carryover: false
        )
        return BudgetMonth(
            month: "2026-06", incomeAvailable: 0, lastMonthOverspent: 0,
            forNextMonth: 0, totalBudgeted: 300, toBudget: 0,
            fromLastMonth: 0, totalIncome: 0, totalSpent: -50,
            totalBalance: 250,
            categoryGroups: [
                BudgetMonthCategoryGroup(
                    id: "visible-group", name: "Visible Group", isIncome: false,
                    hidden: false, budgeted: 100, spent: -20, balance: 80,
                    categories: [individuallyHidden]
                ),
                BudgetMonthCategoryGroup(
                    id: "hidden-group", name: "Hidden Group", isIncome: false,
                    hidden: true, budgeted: 200, spent: -30, balance: 170,
                    categories: [hiddenGroupChild]
                )
            ]
        )
    }
}

actor RecordingBudgetRepository: BudgetRepositoryProtocol {
    private let loadedMonth: LoadedBudgetMonth
    private let assignError: Error?
    private let carryoverError: Error?
    private let suspendsCarryover: Bool
    private let moveError: Error?
    private let templateError: Error?
    private var assignments: [RecordedBudgetAssignment] = []
    private var carryoverUpdates: [RecordedBudgetCarryoverUpdate] = []
    private var moves: [RecordedBudgetMove] = []
    private var templates: [RecordedBudgetTemplate] = []
    private var reviewedTemplateRevisions: [BudgetTemplateReviewRevision] = []
    private var categoryHides: [RecordedCategoryHiddenUpdate] = []
    private var groupHides: [RecordedCategoryGroupHiddenUpdate] = []
    private var didAssignCallbackFinished = false
    private var didMoveCallbackFinished = false
    private var didApplyCallbackFinished = false
    private var carryoverContinuation: CheckedContinuation<Void, Never>?
    private var carryoverStarted = false
    private var carryoverStartedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        loadedMonth: LoadedBudgetMonth = LoadedBudgetMonth(
            availableMonths: ["2026-06"],
            selectedMonth: "2026-06",
            month: try! JSONDecoder().decode(BudgetMonth.self, from: """
            {
              "month": "2026-06",
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
            """.data(using: .utf8)!),
            alerts: []
        ),
        assignError: Error? = nil,
        carryoverError: Error? = nil,
        suspendsCarryover: Bool = false,
        moveError: Error? = nil,
        templateError: Error? = nil
    ) {
        self.loadedMonth = loadedMonth
        self.assignError = assignError
        self.carryoverError = carryoverError
        self.suspendsCarryover = suspendsCarryover
        self.moveError = moveError
        self.templateError = templateError
    }

    func budgets() async throws -> [ActualBudget] {
        []
    }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        loadedMonth
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        loadedMonth
    }

    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        assignments.append(
            RecordedBudgetAssignment(
                categoryID: categoryID,
                budgeted: budgeted,
                budgetID: budgetID,
                month: month
            )
        )

        if let assignError {
            throw assignError
        }

        await didAssign()
        didAssignCallbackFinished = true
        return loadedMonth
    }

    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        carryoverUpdates.append(
            RecordedBudgetCarryoverUpdate(
                categoryID: categoryID,
                carryover: carryover,
                expectedMode: expectedMode,
                budgetID: budgetID,
                startMonth: startMonth
            )
        )

        carryoverStarted = true
        carryoverStartedWaiters.forEach { $0.resume() }
        carryoverStartedWaiters = []
        if suspendsCarryover {
            await withCheckedContinuation { carryoverContinuation = $0 }
        }

        if let carryoverError {
            throw carryoverError
        }

        await didSetCarryover()
        return loadedMonth
    }

    func waitUntilCarryoverStarted() async {
        if carryoverStarted { return }
        await withCheckedContinuation { carryoverStartedWaiters.append($0) }
    }

    func resumeCarryover() {
        carryoverContinuation?.resume()
        carryoverContinuation = nil
    }

    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        if let carryoverError {
            throw carryoverError
        }
        return loadedMonth
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(expectedMode: nil,
            commands: [command],
            budgetID: budgetID,
            month: month,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        for command in commands {
            moves.append(
                RecordedBudgetMove(
                    command: command,
                    budgetID: budgetID,
                    month: month
                )
            )
        }

        if let moveError {
            throw moveError
        }

        await didMove()
        didMoveCallbackFinished = true
        return loadedMonth
    }

    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        templates.append(
            RecordedBudgetTemplate(
                command: command,
                budgetID: budgetID,
                month: month
            )
        )

        if let templateError {
            throw templateError
        }

        await didApply()
        didApplyCallbackFinished = true
        return loadedMonth
    }

    func applyReviewedBudgetTemplateAndRefresh(
        reviewRevision: BudgetTemplateReviewRevision,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        reviewedTemplateRevisions.append(reviewRevision)
        return try await applyBudgetTemplateAndRefresh(
            expectedMode: reviewRevision.modeIdentity,
            command: command, budgetID: budgetID, month: month, didApply: didApply
        )
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        categoryHides.append(
            RecordedCategoryHiddenUpdate(
                categoryID: categoryID,
                hidden: hidden,
                budgetID: budgetID,
                month: month
            )
        )
        await didUpdate()
        return loadedMonth
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        groupHides.append(
            RecordedCategoryGroupHiddenUpdate(
                groupID: groupID,
                hidden: hidden,
                budgetID: budgetID,
                month: month
            )
        )
        await didUpdate()
        return loadedMonth
    }

    func recordedCategoryHides() -> [RecordedCategoryHiddenUpdate] {
        categoryHides
    }

    func onlyCategoryHide() throws -> RecordedCategoryHiddenUpdate {
        try #require(categoryHides.first)
    }

    func onlyGroupHide() throws -> RecordedCategoryGroupHiddenUpdate {
        try #require(groupHides.first)
    }

    func onlyAssignment() throws -> RecordedBudgetAssignment {
        try #require(assignments.first)
    }

    func onlyMove() throws -> RecordedBudgetMove {
        try #require(moves.first)
    }

    func onlyCarryoverUpdate() throws -> RecordedBudgetCarryoverUpdate {
        try #require(carryoverUpdates.first)
    }

    func recordedMoves() -> [RecordedBudgetMove] {
        moves
    }

    func onlyTemplate() throws -> RecordedBudgetTemplate {
        try #require(templates.first)
    }

    func recordedReviewedTemplateRevisions() -> [BudgetTemplateReviewRevision] {
        reviewedTemplateRevisions
    }

    func recordedTemplates() -> [RecordedBudgetTemplate] {
        templates
    }

    func didAssignFinished() -> Bool {
        didAssignCallbackFinished
    }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }

    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }

    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview {
        BudgetActionUndoPreview(actionID: actionID, month: "", entries: [], block: nil)
    }

    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {}

    func didMoveFinished() -> Bool {
        didMoveCallbackFinished
    }

    func didApplyFinished() -> Bool {
        didApplyCallbackFinished
    }
}

struct RecordedBudgetAssignment: Sendable {
    let categoryID: String
    let budgeted: Int
    let budgetID: String
    let month: String
}

struct RecordedBudgetCarryoverUpdate: Sendable {
    let categoryID: String
    let carryover: Bool
    let expectedMode: BudgetModeIdentity?
    let budgetID: String
    let startMonth: String
}

struct RecordedBudgetMove: Sendable {
    let command: BudgetMoveMoneyCommand
    let budgetID: String
    let month: String
}

struct RecordedBudgetTemplate: Sendable {
    let command: BudgetTemplateCommand
    let budgetID: String
    let month: String
}

struct RecordedCategoryHiddenUpdate: Sendable {
    let categoryID: String
    let hidden: Bool
    let budgetID: String
    let month: String
}

struct RecordedCategoryGroupHiddenUpdate: Sendable {
    let groupID: String
    let hidden: Bool
    let budgetID: String
    let month: String
}
