import Foundation
import Testing
@testable import Actualist

struct RuleFormulaEvaluatorTests {
    @Test func numericLiteralUsesActualAmountToInteger() throws {
        let result = try RuleFormulaEvaluator.evaluate("=300", context: .empty)
        #expect(result == .number(30_000))
    }

    @Test func arithmeticAndIntegerToAmountMatchUpstreamVectors() throws {
        #expect(try RuleFormulaEvaluator.evaluate("=100 + 200", context: .empty) == .number(30_000))

        let half = try RuleFormulaEvaluator.evaluate(
            "=INTEGER_TO_AMOUNT(parent_amount) * 0.5",
            context: RuleFormulaContext(
                fields: ["parent_amount": .number(20_000)],
                balanceOfPrefetch: [:],
                today: "2026-08-15"
            )
        )
        #expect(half == .number(10_000))
    }

    @Test func balanceOfUsesPrefetchAndMissingLiteralsAreZero() throws {
        let context = RuleFormulaContext(
            fields: [:],
            balanceOfPrefetch: [
                "Savings": 50_000,
                "550e8400-e29b-41d4-a716-446655440000": 1_200,
            ],
            today: "2026-08-15"
        )
        #expect(
            try RuleFormulaEvaluator.evaluate(#"=BALANCE_OF("Savings") + 100"#, context: context)
                == .number(5_010_000)
        )
        #expect(
            try RuleFormulaEvaluator.evaluate(
                #"=BALANCE_OF("550e8400-e29b-41d4-a716-446655440000")"#,
                context: context
            ) == .number(120_000)
        )
        #expect(try RuleFormulaEvaluator.evaluate(#"=BALANCE_OF("Unknown")"#, context: context) == .number(0))
    }

    @Test func unsupportedAndMalformedFormulasFailClosed() {
        #expect(throws: RuleFormulaEvaluator.EvaluationError.missingEqualsPrefix) {
            try RuleFormulaEvaluator.evaluate("300", context: .empty)
        }
        #expect(throws: RuleFormulaEvaluator.EvaluationError.unsupported) {
            try RuleFormulaEvaluator.evaluate("=QUERY(\"x\")", context: .empty)
        }
        #expect(throws: RuleFormulaEvaluator.EvaluationError.unsupported) {
            try RuleFormulaEvaluator.evaluate("=IF(amount > 0, 1, 0)", context: .empty)
        }
    }

    @Test func extractBalanceOfLiteralsMatchesActual() {
        #expect(
            RuleFormulaEvaluator.extractBalanceOfLiterals(
                #"=BALANCE_OF("Checking") + BALANCE_OF("Checking")"#
            ) == ["Checking"]
        )
        #expect(RuleFormulaEvaluator.extractBalanceOfLiterals(#"=balance_of("Savings")"#) == ["Savings"])
    }

    @Test func javascriptRoundTiesTowardPositiveInfinity() throws {
        #expect(try RuleFormulaEvaluator.javascriptRound(2.5) == 3)
        #expect(try RuleFormulaEvaluator.javascriptRound(-2.5) == -2)
        #expect(try RuleFormulaEvaluator.javascriptRound(-1.5) == -1)
    }
}
