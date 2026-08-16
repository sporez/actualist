import Foundation
import Testing
@testable import Actualist

@MainActor
struct OverspentCoverSelectionViewModelTests {
    @Test func selectionTogglesAndRequiresAtLeastTwoOverspentCategoriesToBegin() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: nil,
            lastMonthOverspent: 0
        )
        let option = try #require(model.overspentCategoryOptions.first)

        #expect(!model.canBeginOverspentCoverSelection)
        model.beginOverspentCoverSelection()
        // One overspent category can still be selected directly; the Select
        // affordance only appears once two or more are overspent.
        #expect(model.isOverspentCoverSelecting)
        model.toggleOverspentCoverSelection(option)
        #expect(model.selectedOverspentCategoryIDs == [option.id])
        model.endOverspentCoverSelection()
        #expect(!model.isOverspentCoverSelecting)
        #expect(model.selectedOverspentCategoryIDs.isEmpty)

        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: -1_000,
            lastMonthOverspent: 0
        )
        #expect(model.canBeginOverspentCoverSelection)
        model.beginOverspentCoverSelection()
        #expect(model.isOverspentCoverSelecting)

        model.toggleOverspentCoverSelection(option)
        #expect(model.selectedOverspentCategoryIDs == [option.id])
        model.toggleOverspentCoverSelection(option)
        #expect(model.selectedOverspentCategoryIDs.isEmpty)

        model.endOverspentCoverSelection()
        #expect(!model.isOverspentCoverSelecting)
    }

    @Test func coverCommandsUseSharedSourceForEverySelectedOverspentCategory() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: -1_000,
            lastMonthOverspent: 0
        )
        let options = model.overspentCategoryOptions
        #expect(options.count == 2)

        model.beginOverspentCoverSelection()
        for option in options {
            model.toggleOverspentCoverSelection(option)
        }

        let toBudgetCommands = model.overspentCoverCommands(source: .toBudget)
        #expect(toBudgetCommands == [
            BudgetMoveMoneyCommand(fromCategoryID: nil, toCategoryID: "mortgage", amount: 2_500),
            BudgetMoveMoneyCommand(fromCategoryID: nil, toCategoryID: "utilities", amount: 1_000)
        ])

        let categoryCommands = model.overspentCoverCommands(
            source: .category(id: "savings", name: "Savings")
        )
        #expect(categoryCommands == [
            BudgetMoveMoneyCommand(fromCategoryID: "savings", toCategoryID: "mortgage", amount: 2_500),
            BudgetMoveMoneyCommand(fromCategoryID: "savings", toCategoryID: "utilities", amount: 1_000)
        ])
    }

    @Test func coverSelectionUsesOneRepositoryMutationAndClearsSelection() async throws {
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: -1_000,
            lastMonthOverspent: 0
        )
        model.selectedMonth = "2026-06"
        let options = model.overspentCategoryOptions

        let refreshedMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: 0,
            secondOverspentBalance: -1_000,
            lastMonthOverspent: 0
        )
        let repository = RecordingBudgetRepository(
            loadedMonth: LoadedBudgetMonth(
                availableMonths: ["2026-06"],
                selectedMonth: "2026-06",
                month: refreshedMonth,
                alerts: []
            )
        )

        model.beginOverspentCoverSelection()
        model.toggleOverspentCoverSelection(options[0])
        let covered = await model.coverOverspentSelection(
            source: .toBudget,
            budgetID: "budget",
            repository: repository
        )

        #expect(covered)
        #expect(!model.isOverspentCoverSelecting)
        #expect(model.selectedOverspentCategoryIDs.isEmpty)
        let recorded = await repository.recordedMoves()
        #expect(recorded.map(\.command) == [
            BudgetMoveMoneyCommand(fromCategoryID: nil, toCategoryID: "mortgage", amount: 2_500)
        ])
        #expect(model.budgetMonth == refreshedMonth)
        #expect(model.overspentCategoryOptions.map(\.id) == ["utilities"])
    }

    @Test func failedCoverSelectionPreservesSelectionAndEntries() async throws {
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: -1_000,
            lastMonthOverspent: 0
        )
        model.selectedMonth = "2026-06"
        let options = model.overspentCategoryOptions
        let repository = RecordingBudgetRepository(
            loadedMonth: LoadedBudgetMonth(
                availableMonths: ["2026-06"],
                selectedMonth: "2026-06",
                month: try Self.decodeBudgetMonth(
                    firstOverspentBalance: 0,
                    secondOverspentBalance: 0,
                    lastMonthOverspent: 0
                ),
                alerts: []
            ),
            moveError: TestError("cover failed")
        )

        model.beginOverspentCoverSelection()
        for option in options {
            model.toggleOverspentCoverSelection(option)
        }
        let covered = await model.coverOverspentSelection(
            source: .toBudget,
            budgetID: "budget",
            repository: repository
        )

        #expect(!covered)
        #expect(model.isOverspentCoverSelecting)
        #expect(model.selectedOverspentCategoryIDs == Set(options.map(\.id)))
        #expect(model.errorMessage == "cover failed")
    }

    @Test func reloadedMonthDropsCategoriesNoLongerOverspentFromSelection() async throws {
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: -1_000,
            lastMonthOverspent: 0
        )
        model.selectedMonth = "2026-06"
        let options = model.overspentCategoryOptions

        model.beginOverspentCoverSelection()
        for option in options {
            model.toggleOverspentCoverSelection(option)
        }

        let repository = RecordingBudgetRepository(
            loadedMonth: LoadedBudgetMonth(
                availableMonths: ["2026-06"],
                selectedMonth: "2026-06",
                month: try Self.decodeBudgetMonth(
                    firstOverspentBalance: -2_500,
                    secondOverspentBalance: 400,
                    lastMonthOverspent: 0
                ),
                alerts: []
            )
        )
        _ = await model.coverOverspentSelection(
            source: .toBudget,
            budgetID: "budget",
            repository: repository
        )

        // Success ends the selection entirely; intersection only matters after
        // refresh paths that keep the selection active.
        #expect(model.selectedOverspentCategoryIDs.isEmpty)

        // Failed submissions keep the selection so the user can retry against
        // the still-visible categories.
        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: -1_000,
            lastMonthOverspent: 0
        )
        model.beginOverspentCoverSelection()
        for option in options {
            model.toggleOverspentCoverSelection(option)
        }
        let failingRepository = RecordingBudgetRepository(
            loadedMonth: LoadedBudgetMonth(
                availableMonths: ["2026-06"],
                selectedMonth: "2026-06",
                month: try Self.decodeBudgetMonth(
                    firstOverspentBalance: -2_500,
                    secondOverspentBalance: 400,
                    lastMonthOverspent: 0
                ),
                alerts: []
            ),
            moveError: TestError("refresh raced")
        )
        _ = await model.coverOverspentSelection(
            source: .toBudget,
            budgetID: "budget",
            repository: failingRepository
        )
        #expect(model.selectedOverspentCategoryIDs == Set(options.map(\.id)))
    }

    @Test func coverSourcePickerExcludesSelectedAndOverspentCategories() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: -1_000,
            lastMonthOverspent: 0
        )

        // No selection yet: the picker excludes every overspent category, so
        // with both visible categories overspent there is nothing to pick.
        #expect(model.overspentCoverSourcePickerGroups().isEmpty)

        // Give one category a positive balance so it is a valid funding source.
        model.budgetMonth = try Self.decodeBudgetMonth(
            firstOverspentBalance: -2_500,
            secondOverspentBalance: 4_000,
            lastMonthOverspent: 0
        )
        model.beginOverspentCoverSelection()
        for option in model.overspentCategoryOptions {
            model.toggleOverspentCoverSelection(option)
        }

        let groups = model.overspentCoverSourcePickerGroups()
        #expect(groups.count == 1)
        #expect(groups.first?.name == "Monthly Bills")
        #expect(groups.first?.options.map(\.id) == ["utilities"])
        #expect(groups.first?.options.first?.valueText == "$40.00")
    }

    @Test func coverSourcePickerIncludesToBudgetOptionFromIncome() throws {
        // A visible income category makes the synthetic "To Budget" source
        // available so overspent categories can be covered from available income.
        let model = BudgetViewModel()
        model.budgetMonth = try Self.decodeBudgetMonthWithIncome(
            overspentBalance: -2_500,
            toBudget: 3_000
        )
        model.beginOverspentCoverSelection()
        for option in model.overspentCategoryOptions {
            model.toggleOverspentCoverSelection(option)
        }

        let groups = model.overspentCoverSourcePickerGroups()
        let toBudgetGroup = try #require(groups.first(where: { $0.id == BudgetMoveMoneyDestination.toBudget.id }))
        #expect(toBudgetGroup.name == "To Budget")
        #expect(toBudgetGroup.options.count == 1)
        let toBudgetOption = try #require(toBudgetGroup.options.first)
        #expect(toBudgetOption.title == BudgetMoveMoneyDestination.toBudget.title)
        #expect(toBudgetOption.amount == 3_000)
        #expect(toBudgetOption.valueText == "$30.00")

        // The "To Budget" option routes to `.toBudget`; a real expense category
        // option routes to `.category`.
        #expect(model.coverSource(for: toBudgetOption) == .toBudget)
        let expenseOption = try #require(groups.first(where: { $0.id != BudgetMoveMoneyDestination.toBudget.id })?.options.first)
        #expect(model.coverSource(for: expenseOption) == .category(id: expenseOption.id, name: expenseOption.title))
    }

    private static func decodeBudgetMonth(
        firstOverspentBalance: Int,
        secondOverspentBalance: Int?,
        lastMonthOverspent: Int
    ) throws -> BudgetMonth {
        let secondCategoryJSON = secondOverspentBalance.map { balance in
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
          "toBudget": 0,
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
                  "budgeted": 0,
                  "spent": 0,
                  "balance": \(firstOverspentBalance),
                  "carryover": false
                },
                \(secondCategoryJSON)
                {
                  "id": "old",
                  "name": "Hidden",
                  "is_income": false,
                  "hidden": true,
                  "group_id": "bills",
                  "budgeted": 0,
                  "spent": 0,
                  "balance": -9999,
                  "carryover": false
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        return try JSONDecoder().decode(BudgetMonth.self, from: json)
    }

    private static func decodeBudgetMonthWithIncome(
        overspentBalance: Int,
        toBudget: Int
    ) throws -> BudgetMonth {
        let json = """
        {
          "month": "2026-06",
          "incomeAvailable": 0,
          "lastMonthOverspent": 0,
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
              "categories": [
                {
                  "id": "salary",
                  "name": "💰 Salary",
                  "is_income": true,
                  "hidden": false,
                  "group_id": "income",
                  "budgeted": 0,
                  "spent": 0,
                  "balance": 0,
                  "carryover": false
                }
              ]
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
                  "budgeted": 0,
                  "spent": 0,
                  "balance": \(overspentBalance),
                  "carryover": false
                },
                {
                  "id": "utilities",
                  "name": "🧹 Utilities",
                  "is_income": false,
                  "hidden": false,
                  "group_id": "bills",
                  "budgeted": 0,
                  "spent": 0,
                  "balance": 4000,
                  "carryover": false
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        return try JSONDecoder().decode(BudgetMonth.self, from: json)
    }
}
