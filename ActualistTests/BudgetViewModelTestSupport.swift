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
                  "carryover": \(visibleCategoryCarryover)
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
}

actor RecordingBudgetRepository: BudgetRepositoryProtocol {
    private let loadedMonth: LoadedBudgetMonth
    private let assignError: Error?
    private let carryoverError: Error?
    private let moveError: Error?
    private let templateError: Error?
    private var assignments: [RecordedBudgetAssignment] = []
    private var carryoverUpdates: [RecordedBudgetCarryoverUpdate] = []
    private var moves: [RecordedBudgetMove] = []
    private var templates: [RecordedBudgetTemplate] = []
    private var didAssignCallbackFinished = false
    private var didMoveCallbackFinished = false
    private var didApplyCallbackFinished = false

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
        moveError: Error? = nil,
        templateError: Error? = nil
    ) {
        self.loadedMonth = loadedMonth
        self.assignError = assignError
        self.carryoverError = carryoverError
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

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
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

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        carryoverUpdates.append(
            RecordedBudgetCarryoverUpdate(
                categoryID: categoryID,
                carryover: carryover,
                budgetID: budgetID,
                startMonth: startMonth
            )
        )

        if let carryoverError {
            throw carryoverError
        }

        await didSetCarryover()
        return loadedMonth
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        try await moveMoneyAndRefresh(
            commands: [command],
            budgetID: budgetID,
            month: month,
            didMove: didMove
        )
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
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

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
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

    func didAssignFinished() -> Bool {
        didAssignCallbackFinished
    }

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
