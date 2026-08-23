import Foundation
import Testing
@testable import Actualist

struct RuleRankingTests {
    @Test func exactMatchRulesRunAfterContainsSoTheyOverride() {
        let contains = rule(
            id: "a-contains",
            stage: .normal,
            conditions: [RuleCondition(field: "notes", operation: "contains", value: .string("x"))],
            actions: [RuleAction(operation: "set", field: "notes", value: .string("contains"))]
        )
        let exact = rule(
            id: "z-is",
            stage: .normal,
            conditions: [RuleCondition(field: "notes", operation: "is", value: .string("x"))],
            actions: [RuleAction(operation: "set", field: "notes", value: .string("exact"))]
        )

        #expect(RuleRanking.score(of: contains) == 0)
        #expect(RuleRanking.score(of: exact) == 20)
        #expect(RuleRanking.rank([exact, contains]).map(\.id) == ["a-contains", "z-is"])
    }

    @Test func sameScoreFallsBackToRuleID() {
        let first = rule(
            id: "aaa",
            conditions: [RuleCondition(field: "notes", operation: "is", value: .string("x"))]
        )
        let second = rule(
            id: "bbb",
            conditions: [RuleCondition(field: "notes", operation: "is", value: .string("y"))]
        )
        #expect(RuleRanking.rank([second, first]).map(\.id) == ["aaa", "bbb"])
    }

    @Test func stagesStayPreNormalPostRegardlessOfScore() {
        let post = rule(
            id: "post-low",
            stage: .post,
            conditions: [RuleCondition(field: "notes", operation: "contains", value: .string("x"))]
        )
        let pre = rule(
            id: "pre-high",
            stage: .pre,
            conditions: [RuleCondition(field: "notes", operation: "is", value: .string("x"))]
        )
        let normal = rule(
            id: "normal",
            stage: .normal,
            conditions: [RuleCondition(field: "notes", operation: "is", value: .string("x"))]
        )
        #expect(RuleRanking.rank([post, normal, pre]).map(\.id) == ["pre-high", "normal", "post-low"])
    }

    @Test func unknownOperationZerosTheScoreSoFar() {
        let rule = rule(
            id: "mixed",
            conditions: [
                RuleCondition(field: "notes", operation: "is", value: .string("x")),
                RuleCondition(field: "notes", operation: "hasAnyTag", value: .string("#x"))
            ]
        )
        #expect(RuleRanking.score(of: rule) == 0)
    }

    private func rule(
        id: String,
        stage: RuleStage = .normal,
        conditions: [RuleCondition],
        actions: [RuleAction] = [RuleAction(operation: "set", field: "notes", value: .string("n"))]
    ) -> ManagedRule {
        ManagedRule(
            id: id,
            draft: RuleDraft(
                stage: stage,
                conditionsJoin: .and,
                conditions: conditions,
                actions: actions
            ),
            rawStage: stage.databaseValue,
            rawConditionsJSON: "[]",
            rawActionsJSON: "[]",
            payeeIDs: [],
            isCompletedScheduleRule: false
        )
    }
}
