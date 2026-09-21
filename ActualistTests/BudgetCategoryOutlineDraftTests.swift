import Testing
@testable import Actualist

struct BudgetCategoryOutlineDraftTests {
    @Test func unchangedOutlineHasNoCommandAndReordersWithinAGroup() throws {
        var draft = BudgetCategoryOutlineDraft(groups: groups, isTrackingBudget: false)
        #expect(draft.command == nil)

        try draft.moveCategory(id: "fuel", toGroupID: "everyday", beforeCategoryID: "food")
        #expect(draft.groups[0].categories.map(\.id) == ["fuel", "food"])
        #expect(draft.command?.groups[0].categoryIDs == ["fuel", "food"])
    }

    @Test func movesAcrossGroupsAndRejectsDuplicateAndIncomeDestinations() throws {
        var draft = BudgetCategoryOutlineDraft(groups: groups, isTrackingBudget: true)
        try draft.moveCategory(id: "fuel", toGroupID: "bills", beforeCategoryID: nil)
        #expect(draft.groups[1].categories.map(\.id) == ["rent", "fuel"])

        var duplicate = BudgetCategoryOutlineDraft(groups: duplicateGroups, isTrackingBudget: true)
        #expect(throws: LocalFirstError.invalidLocalWrite("A category with the name Food already exists.")) {
            try duplicate.moveCategory(id: "food", toGroupID: "bills", beforeCategoryID: nil)
        }
        #expect(throws: LocalFirstError.invalidLocalWrite("income and expense categories cannot be mixed")) {
            try draft.moveCategory(id: "food", toGroupID: "income", beforeCategoryID: nil)
        }
    }

    @Test func envelopeOmitsIncomeAndGroupMovesStayWithinTheirKind() throws {
        let envelope = BudgetCategoryOutlineDraft(groups: groups, isTrackingBudget: false)
        #expect(envelope.groups.map(\.id) == ["everyday", "bills"])

        var tracking = BudgetCategoryOutlineDraft(groups: groups, isTrackingBudget: true)
        try tracking.moveGroup(id: "bills", beforeGroupID: "everyday")
        #expect(tracking.groups.map(\.id) == ["bills", "everyday", "income"])
        #expect(throws: LocalFirstError.invalidLocalWrite("income and expense groups cannot be mixed")) {
            try tracking.moveGroup(id: "everyday", beforeGroupID: "income")
        }
    }

    @Test @MainActor func reorderCancelAndUnchangedSaveNeverCallRepository() async {
        let repository = CategoryLifecycleRecordingRepository()
        let workflow = BudgetCategoryReorderWorkflow()
        workflow.begin(groups: groups, isTrackingBudget: false)
        workflow.cancel()
        #expect(await workflow.save(selectedMonth: "2026-07", budgetID: "budget", repository: repository) == nil)

        workflow.begin(groups: groups, isTrackingBudget: false)
        let unchanged = await workflow.save(selectedMonth: "2026-07", budgetID: "budget", repository: repository)
        #expect(unchanged == nil)
        #expect(await repository.outlines.isEmpty)
    }

    private var groups: [BudgetMonthCategoryGroup] {
        [
            group("everyday", "Everyday", false, [category("food", "Food", false, "everyday"), category("fuel", "Fuel", false, "everyday")]),
            group("bills", "Bills", false, [category("rent", "Rent", false, "bills")]),
            group("income", "Income", true, [category("salary", "Salary", true, "income")])
        ]
    }

    private var duplicateGroups: [BudgetMonthCategoryGroup] {
        [
            group("everyday", "Everyday", false, [category("food", "Food", false, "everyday")]),
            group("bills", "Bills", false, [category("other-food", "food", false, "bills")])
        ]
    }
}

private func group(
    _ id: String,
    _ name: String,
    _ isIncome: Bool,
    _ categories: [BudgetMonthCategory]
) -> BudgetMonthCategoryGroup {
    BudgetMonthCategoryGroup(
        id: id, name: name, isIncome: isIncome, hidden: false,
        budgeted: 0, spent: 0, balance: 0, categories: categories
    )
}

private func category(
    _ id: String,
    _ name: String,
    _ isIncome: Bool,
    _ groupID: String
) -> BudgetMonthCategory {
    BudgetMonthCategory(
        id: id, name: name, isIncome: isIncome, hidden: false, groupID: groupID,
        budgeted: 0, spent: 0, balance: 0, carryover: false
    )
}
