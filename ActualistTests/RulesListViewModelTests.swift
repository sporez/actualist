import Foundation
import Testing
@testable import Actualist

@MainActor
struct RulesListViewModelTests {
    private let fixtures = LocalFirstActualStoreTests()
    private static let rulesTableSQL = """
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            stage TEXT,
            conditions TEXT,
            actions TEXT,
            conditions_op TEXT DEFAULT 'and',
            tombstone INTEGER DEFAULT 0
        );
        """

    @Test func doubleDuplicateWritesOnceAndFailedRefreshKeepsPreviousOptions() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.rulesTableSQL)
        let appState = try fixtures.makeAppState(for: bundle)
        let draft = RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [RuleCondition(field: "payee", operation: "is", value: .string("coffee"), type: "id")],
            actions: [RuleAction(operation: "set", field: "category", value: .string("groceries"), type: "id")]
        )
        try await bundle.store.createRuleAndRefresh(budgetID: "group-1", draft: draft)
        let model = RulesListViewModel()
        await model.load(scope: .all, using: appState)
        let original = try #require(model.rules.first)
        #expect(model.options != nil)

        let first = Task { await model.duplicate(original, using: appState) }
        let second = Task { await model.duplicate(original, using: appState) }
        let results = [await first.value, await second.value]

        #expect(results.filter { $0 }.count == 1)
        #expect(bundle.store.cachedRules(budgetID: "group-1")?.count == 2)
        #expect(!model.isSubmitting)

        bundle.store.closeOpenBudget()
        await model.load(scope: .all, using: appState)
        #expect(model.options != nil)
        #expect(model.errorMessage != nil)
    }

    @Test func payeeScopeHidesOtherAndCompletedRules() {
        let viewModel = RulesListViewModel()
        viewModel.rules = [
            rule(id: "keep", payeeIDs: ["coffee"], stage: .normal),
            rule(id: "other", payeeIDs: ["market"], stage: .normal),
            rule(id: "done", payeeIDs: ["coffee"], stage: .normal, completed: true)
        ]
        #expect(viewModel.displayedRules(for: .payee("coffee")).map(\.id) == ["keep"])
        #expect(viewModel.displayedRules(for: .all).map(\.id) == ["keep", "other"])
    }

    @Test func searchMatchesHumanReadableSummary() {
        let viewModel = RulesListViewModel()
        viewModel.options = RuleEditorOptions(
            accounts: [],
            categories: [RuleEditorChoice(id: "groceries", name: "Groceries")],
            categoryGroups: [],
            payees: [RuleEditorChoice(id: "coffee", name: "Coffee Shop")]
        )
        viewModel.rules = [
            rule(
                id: "coffee-rule",
                payeeIDs: ["coffee"],
                stage: .pre,
                conditionPayee: "coffee",
                actionCategory: "groceries"
            ),
            rule(id: "notes-rule", payeeIDs: [], stage: .post)
        ]
        viewModel.searchText = "groceries"
        #expect(viewModel.displayedRules(for: .all).map(\.id) == ["coffee-rule"])
        viewModel.searchText = "coffee shop"
        #expect(viewModel.displayedRules(for: .all).map(\.id) == ["coffee-rule"])
    }

    @Test func sectionsFollowPreNormalPostAndOmitEmpty() {
        let viewModel = RulesListViewModel()
        viewModel.rules = [
            rule(id: "post", payeeIDs: [], stage: .post),
            rule(id: "pre", payeeIDs: [], stage: .pre),
            rule(id: "normal", payeeIDs: [], stage: .normal)
        ]
        #expect(viewModel.sections(for: .all).map(\.stage) == [.pre, .normal, .post])
        #expect(viewModel.sections(for: .all).map { $0.rules.map(\.id) } == [["pre"], ["normal"], ["post"]])
    }

    private func rule(
        id: String,
        payeeIDs: Set<String>,
        stage: RuleStage,
        completed: Bool = false,
        conditionPayee: String? = nil,
        actionCategory: String? = nil
    ) -> ManagedRule {
        let condition = RuleCondition(
            field: "description",
            operation: "is",
            value: .string(conditionPayee ?? "x"),
            type: "id"
        )
        let action = RuleAction(
            operation: "set",
            field: "category",
            value: actionCategory.map(RuleJSONValue.string) ?? .null,
            type: "id"
        )
        return ManagedRule(
            id: id,
            draft: RuleDraft(
                stage: stage,
                conditionsJoin: .and,
                conditions: [condition],
                actions: [action]
            ),
            rawStage: stage.databaseValue,
            rawConditionsJSON: "[]",
            rawActionsJSON: "[]",
            payeeIDs: payeeIDs,
            isCompletedScheduleRule: completed
        )
    }
}
