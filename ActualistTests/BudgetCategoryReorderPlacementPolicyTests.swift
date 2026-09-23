import Testing
@testable import Actualist

struct BudgetCategoryReorderPlacementPolicyTests {
    @Test func groupPlacementUsesExplicitHeaderEdges() {
        let groups = [group("first"), group("second"), group("third"), group("income", income: true)]

        #expect(groupPlacement(moving: "first", over: "second", edge: .before, groups: groups)?.beforeGroupID == "second")
        #expect(groupPlacement(moving: "first", over: "second", edge: .after, groups: groups)?.beforeGroupID == "third")
        #expect(groupPlacement(moving: "first", over: "third", edge: .after, groups: groups)?.beforeGroupID == nil)
        #expect(groupPlacement(moving: "third", over: "second", edge: .before, groups: groups)?.beforeGroupID == "second")
        #expect(groupPlacement(moving: "first", over: "income", edge: .before, groups: groups) == nil)
        #expect(groupPlacement(moving: "missing", over: "first", edge: .before, groups: groups) == nil)
    }

    @Test func categoryPlacementMovesPastEnteredRowsAndAcrossCompatibleGroups() {
        let groups = [
            group("first", categories: [category("a"), category("b"), category("c")]),
            group("second", categories: [category("d"), category("e")]),
            group("income", income: true, categories: [category("salary", income: true)])
        ]

        #expect(categoryPlacement(moving: "a", over: "b", in: "first", groups: groups)
            == .init(groupID: "first", beforeCategoryID: "c"))
        #expect(categoryPlacement(moving: "c", over: "b", in: "first", groups: groups)
            == .init(groupID: "first", beforeCategoryID: "b"))
        #expect(categoryPlacement(moving: "a", over: "d", in: "second", groups: groups)
            == .init(groupID: "second", beforeCategoryID: "e"))
        #expect(categoryPlacement(moving: "e", over: "b", in: "first", groups: groups)
            == .init(groupID: "first", beforeCategoryID: "b"))
        #expect(categoryPlacement(moving: "a", over: "salary", in: "income", groups: groups) == nil)
    }

    private func groupPlacement(
        moving: String,
        over destination: String,
        edge: BudgetCategoryReorderPlacementPolicy.GroupEdge,
        groups: [BudgetCategoryOutlineDraft.Group]
    ) -> BudgetCategoryReorderPlacementPolicy.GroupPlacement? {
        BudgetCategoryReorderPlacementPolicy.groupPlacement(
            movingGroupID: moving,
            overGroupID: destination,
            edge: edge,
            groups: groups
        )
    }

    private func categoryPlacement(
        moving: String,
        over destination: String,
        in groupID: String,
        groups: [BudgetCategoryOutlineDraft.Group]
    ) -> BudgetCategoryReorderPlacementPolicy.CategoryPlacement? {
        BudgetCategoryReorderPlacementPolicy.categoryPlacement(
            movingCategoryID: moving,
            overCategoryID: destination,
            destinationGroupID: groupID,
            groups: groups
        )
    }

    private func group(
        _ id: String,
        income: Bool = false,
        categories: [BudgetCategoryOutlineDraft.Category] = []
    ) -> BudgetCategoryOutlineDraft.Group {
        .init(id: id, name: id, isIncome: income, hidden: false, categories: categories)
    }

    private func category(
        _ id: String,
        income: Bool = false
    ) -> BudgetCategoryOutlineDraft.Category {
        .init(id: id, name: id, isIncome: income, hidden: false)
    }
}
