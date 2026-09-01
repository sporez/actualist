import Foundation
import Testing
@testable import Actualist

struct RuleSplitActionExecutorTests {
    @Test func oracleFamiliesMatchOneBasedAllocationAndChildExclusion() throws {
        let fixture = try decode(SplitRuleFixture.self, from: fixtureURL)
        let cases = Dictionary(uniqueKeysWithValues: fixture.cases.map { ($0.id, $0) })

        try assertCase(
            "index-zero-whole-transaction-and-one-based-children",
            in: cases,
            actions: [
                RuleAction(operation: "append-notes", value: .string(" whole"), options: ["splitIndex": .number(0)]),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(-4_000),
                    options: ["splitIndex": .number(1), "method": .string("fixed-amount")]
                ),
                RuleAction(
                    operation: "set",
                    field: "category",
                    value: .string("groceries"),
                    options: ["splitIndex": .number(1)]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["splitIndex": .number(2), "method": .string("remainder")]
                ),
                RuleAction(
                    operation: "set",
                    field: "category",
                    value: .null,
                    options: ["splitIndex": .number(2)]
                ),
            ]
        )
        try assertCase(
            "negative-half-percent-rounding",
            in: cases,
            parentAmount: -5,
            actions: percentRemainder
        )
        try assertCase(
            "positive-half-percent-rounding",
            in: cases,
            parentAmount: 5,
            actions: percentRemainder
        )
        try assertCase(
            "multiple-negative-remainders-adjust-highest-index",
            in: cases,
            parentAmount: -5,
            actions: [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["splitIndex": .number(1), "method": .string("remainder")]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["splitIndex": .number(2), "method": .string("remainder")]
                ),
            ]
        )
        try assertCase(
            "fixed-before-percent-before-remainder",
            in: cases,
            parentAmount: 50,
            actions: [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(100),
                    options: ["splitIndex": .number(1), "method": .string("fixed-amount")]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(50),
                    options: ["splitIndex": .number(2), "method": .string("fixed-percent")]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["splitIndex": .number(3), "method": .string("remainder")]
                ),
            ]
        )
        try assertCase(
            "formula-and-remainder",
            in: cases,
            parentAmount: 100_000,
            actions: [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: [
                        "splitIndex": .number(1),
                        "method": .string("formula"),
                        "formula": .string("=300"),
                    ]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["splitIndex": .number(2), "method": .string("remainder")]
                ),
            ]
        )

        let childInput = try #require(cases["effective-child-input-is-not-split"])
        let child = SplitTransactionFamilyOps.makeChild(
            parent: baseParent(),
            data: SplitTransactionPatch(id: "existing-child", amount: -10_000)
        )
        let outcome = RuleSplitActionExecutor.execActions(
            [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(-4_000),
                    options: ["splitIndex": .number(1), "method": .string("fixed-amount")]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["splitIndex": .number(2), "method": .string("remainder")]
                ),
            ],
            transaction: child
        )
        guard case .applied(let result) = outcome else {
            Issue.record("child input should not fail closed")
            return
        }
        #expect(result.isChild)
        #expect(result.subtransactions.isEmpty)
        #expect(result.amount == childInput.expected.parent.amount)
        #expect(childInput.expected.children.isEmpty)
    }

    @Test func oneBasedSplitActionsSerializeWithoutReinterpretingIndexZero() throws {
        let actions = [
            RuleAction(operation: "append-notes", value: .string(" whole"), options: ["splitIndex": .number(0)]),
            RuleAction(
                operation: "set-split-amount",
                value: .number(-4_000),
                options: ["splitIndex": .number(1), "method": .string("fixed-amount")]
            ),
            RuleAction(
                operation: "set-split-amount",
                value: .number(0),
                options: ["splitIndex": .number(2), "method": .string("remainder")]
            ),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(actions)
        let decoded = try JSONDecoder().decode([RuleAction].self, from: data)
        let indexes = decoded.map { $0.splitIndex }
        let executable = decoded.map(\.canExecuteAtRuntime)
        let editable = decoded.map(\.canRoundTripAndEvaluate)
        #expect(indexes == [Optional(0), Optional(1), Optional(2)])
        #expect(executable == [true, true, true])
        #expect(editable == [false, false, false])
    }

    @Test func unsupportedFormulaSplitRulesFailClosed() {
        let outcome = RuleSplitActionExecutor.execActions(
            [
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: [
                        "splitIndex": .number(1),
                        "method": .string("formula"),
                        "formula": .string("=QUERY(\"x\")"),
                    ]
                ),
                RuleAction(
                    operation: "set-split-amount",
                    value: .number(0),
                    options: ["splitIndex": .number(2), "method": .string("remainder")]
                ),
            ],
            transaction: baseParent()
        )
        #expect(outcome == .failedClosed)
    }

    private var percentRemainder: [RuleAction] {
        [
            RuleAction(
                operation: "set-split-amount",
                value: .number(50),
                options: ["splitIndex": .number(1), "method": .string("fixed-percent")]
            ),
            RuleAction(
                operation: "set-split-amount",
                value: .number(0),
                options: ["splitIndex": .number(2), "method": .string("remainder")]
            ),
        ]
    }

    private func assertCase(
        _ id: String,
        in cases: [String: SplitRuleFixture.Case],
        parentAmount: Int? = nil,
        actions: [RuleAction]
    ) throws {
        let expected = try #require(cases[id]).expected
        var parent = baseParent()
        if let parentAmount {
            parent.amount = parentAmount
        }
        let outcome = RuleSplitActionExecutor.execActions(actions, transaction: parent)
        guard case .applied(let result) = outcome else {
            Issue.record("\(id) failed closed")
            return
        }
        assertSemanticFamily(result, expected)
    }

    private func assertSemanticFamily(_ result: SplitTransactionRecord, _ expected: SplitRuleFixture.Family) {
        #expect(result.amount == expected.parent.amount)
        #expect(result.account == expected.parent.account)
        #expect(result.date == expected.parent.date)
        #expect(result.category == expected.parent.category)
        #expect(result.payee == expected.parent.payee)
        #expect(result.notes == expected.parent.notes)
        #expect(result.cleared == expected.parent.cleared)
        #expect(result.reconciled == expected.parent.reconciled)
        #expect(result.startingBalance == expected.parent.startingBalance)
        #expect(result.isParent == expected.parent.isParent)
        #expect(result.isChild == expected.parent.isChild)
        #expect(result.error == expected.parent.error)
        #expect(result.subtransactions.map(\.amount) == expected.children.map(\.amount))
        #expect(result.subtransactions.map(\.category) == expected.children.map(\.category))
        #expect(result.subtransactions.map(\.payee) == expected.children.map(\.payee))
        #expect(result.subtransactions.map(\.notes) == expected.children.map(\.notes))
        #expect(result.subtransactions.map(\.isChild) == expected.children.map(\.isChild))
        #expect(result.subtransactions.map(\.parentID) == expected.children.map(\.parentID))
        #expect(result.subtransactions.map(\.cleared) == expected.children.map(\.cleared))
    }

    private func baseParent(amount: Int = -10_000) -> SplitTransactionRecord {
        SplitTransactionRecord(
            id: "parent-1",
            amount: amount,
            account: "checking",
            date: "2026-08-15",
            category: "groceries",
            payee: "coffee",
            notes: "parent note",
            cleared: true,
            reconciled: false,
            startingBalance: false,
            sortOrder: 100
        )
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ActualistTests/Fixtures/ActualCore26_8_1/Splits/split-rule-cases.json")
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

private struct SplitRuleFixture: Decodable {
    let cases: [Case]

    struct Case: Decodable {
        let id: String
        let expected: Family
    }

    struct Family: Decodable {
        let parent: SplitTransactionRecord
        let children: [SplitTransactionRecord]
    }
}
