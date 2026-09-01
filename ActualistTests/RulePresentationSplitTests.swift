import Foundation
import Testing
@testable import Actualist

struct RulePresentationSplitTests {
    @Test func readOnlyR04GroupsApplyToAllAndNumberedSplits() {
        let travelID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let childAID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let rule = splitRule(
            conditionsJSON: """
            [{"op":"is","field":"imported_payee","value":"ACTUALIST-SPLIT:R04","type":"string"}]
            """,
            actionsJSON: """
            [
              {"op":"set","field":"notes","value":"ACTUALIST-SPLIT:R04:PARENT","type":"string","options":{"splitIndex":0}},
              {"op":"set-split-amount","value":-2500,"type":"number","options":{"splitIndex":1,"method":"fixed-amount"}},
              {"op":"set","field":"category","value":"\(travelID)","type":"id","options":{"splitIndex":1}},
              {"op":"set","field":"payee","value":"\(childAID)","type":"id","options":{"splitIndex":1}},
              {"op":"set","field":"notes","value":"ACTUALIST-SPLIT:R04:CHILD","type":"string","options":{"splitIndex":1}},
              {"op":"set-split-amount","value":0,"type":"number","options":{"splitIndex":2,"method":"remainder"}},
              {"op":"set","field":"category","value":null,"type":"id","options":{"splitIndex":2}},
              {"op":"set","field":"payee","value":null,"type":"id","options":{"splitIndex":2}}
            ]
            """
        )
        let options = RuleEditorOptions(
            accounts: [],
            categories: [RuleEditorChoice(id: travelID, name: "SPLIT · Travel")],
            categoryGroups: [],
            payees: [RuleEditorChoice(id: childAID, name: "SPLIT · Child A")]
        )
        let details = rule.readOnlyDetails(options: options)
        let joined = details.joined(separator: "\n")
        let summary = rule.summary(options: options)

        #expect(details.contains("Apply to all"))
        #expect(details.contains("Split 1"))
        #expect(details.contains("Split 2"))
        #expect(details.firstIndex(of: "Apply to all")! < details.firstIndex(of: "Split 1")!)
        #expect(details.firstIndex(of: "Split 1")! < details.firstIndex(of: "Split 2")!)
        #expect(joined.contains("Action: Set Notes ACTUALIST-SPLIT:R04:PARENT"))
        #expect(joined.contains("Action: Allocate a fixed amount: \(BudgetCurrency.usd.formatted(-2_500))"))
        #expect(joined.contains("Set Category SPLIT · Travel"))
        #expect(joined.contains("Set Payee SPLIT · Child A"))
        #expect(joined.contains("Set Notes ACTUALIST-SPLIT:R04:CHILD"))
        #expect(joined.contains("Action: Allocate an equal portion of the remainder"))
        #expect(joined.contains("Set Category None"))
        #expect(joined.contains("Set Payee None"))
        #expect(!joined.contains(travelID))
        #expect(!joined.contains(childAID))
        #expect(!joined.contains("splitIndex"))
        #expect(!joined.contains("fixed-amount"))
        #expect(!joined.contains("set-split-amount"))

        #expect(summary.contains("Apply to all: set notes ACTUALIST-SPLIT:R04:PARENT"))
        #expect(summary.contains("Split 1: allocate a fixed amount: \(BudgetCurrency.usd.formatted(-2_500))"))
        #expect(summary.contains("Split 2: allocate an equal portion of the remainder"))
        #expect(!summary.contains("then set notes"))
    }

    @Test func childOnlySplitRuleOmitsEmptyApplyToAll() {
        let groceriesID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let rule = splitRule(
            conditionsJSON: """
            [{"op":"is","field":"imported_payee","value":"ACTUALIST-SPLIT:R01","type":"string"}]
            """,
            actionsJSON: """
            [
              {"op":"set-split-amount","value":-4000,"type":"number","options":{"splitIndex":1,"method":"fixed-amount"}},
              {"op":"set","field":"category","value":"\(groceriesID)","type":"id","options":{"splitIndex":1}},
              {"op":"set-split-amount","value":0,"type":"number","options":{"splitIndex":2,"method":"remainder"}},
              {"op":"set","field":"category","value":"\(groceriesID)","type":"id","options":{"splitIndex":2}}
            ]
            """
        )
        let options = RuleEditorOptions(
            accounts: [],
            categories: [RuleEditorChoice(id: groceriesID, name: "SPLIT · Groceries")],
            categoryGroups: [],
            payees: []
        )
        let details = rule.readOnlyDetails(options: options)
        #expect(!details.contains("Apply to all"))
        #expect(details.contains("Split 1"))
        #expect(details.contains("Split 2"))
        #expect(rule.summary(options: options).contains("Split 1:"))
        #expect(!rule.summary(options: options).contains("Apply to all"))
    }

    @Test func percentAndFormulaMethodsAreNotCurrency() {
        let actions = [
            RuleAction(
                operation: "set-split-amount",
                value: .number(50),
                type: "number",
                options: ["splitIndex": .number(1), "method": .string("fixed-percent")]
            ),
            RuleAction(
                operation: "set-split-amount",
                value: .number(0),
                type: "number",
                options: [
                    "splitIndex": .number(1),
                    "method": .string("formula"),
                    "formula": .string("=BALANCE_OF(\"SPLIT · Balance\") / 100")
                ]
            )
        ]
        let summary = RulePresentation.groupedActionSummary(actions, options: nil)
        #expect(summary.contains("allocate a fixed percent of the remainder: 50%"))
        #expect(summary.contains("allocate based on a formula: =BALANCE_OF(\"SPLIT · Balance\") / 100"))
        #expect(!summary.contains(BudgetCurrency.usd.formatted(50)))
        #expect(!summary.contains("set split amount, set split amount"))
    }

    @Test func ordinaryRuleStaysUngrouped() {
        let actions = [
            RuleAction(operation: "set", field: "category", value: .string("groceries"), type: "id")
        ]
        let details = RulePresentation.groupedActionDetails(
            actions,
            options: RuleEditorOptions(
                accounts: [],
                categories: [RuleEditorChoice(id: "groceries", name: "Groceries")],
                categoryGroups: [],
                payees: []
            )
        )
        #expect(details == ["Action: Set Category Groceries"])
        #expect(!details.contains("Apply to all"))
        #expect(!details.contains(where: { $0.hasPrefix("Split ") }))
    }

    private func splitRule(conditionsJSON: String, actionsJSON: String) -> ManagedRule {
        ManagedRule(
            id: "split-rule",
            draft: nil,
            rawStage: nil,
            rawConditionsJSON: conditionsJSON,
            rawActionsJSON: actionsJSON,
            payeeIDs: [],
            isCompletedScheduleRule: false
        )
    }
}
