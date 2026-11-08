import Foundation
import Testing
@testable import Actualist

/// Actual v26.11.0 `Action.executeFormulaSync`: `amount`, `balance`,
/// `parent_amount` and `BALANCE_OF` read as the amounts the app shows, and the
/// result comes back unconverted; the caller writing an amount converts it with
/// `amountToInteger` (`packages/loot-core/src/server/rules/action.ts`).
struct RuleFormulaEvaluatorTests {
    private func context(_ fields: [String: RuleFormulaValue], balances: [String: Int] = [:]) -> RuleFormulaContext {
        RuleFormulaContext(fields: fields, balanceOfPrefetch: balances, today: "2026-08-15")
    }

    @Test func literalsAndArithmeticReturnTheRawAmount() throws {
        #expect(try RuleFormulaEvaluator.evaluate("=300", context: .empty) == .number(300))
        #expect(try RuleFormulaEvaluator.evaluate("=100 + 200", context: .empty) == .number(300))
        #expect(try RuleFormulaEvaluator.amountToInteger(300) == 30_000)
    }

    @Test func monetaryFieldsReadAsAmounts() throws {
        let fields: [String: RuleFormulaValue] = [
            "amount": .number(-4_250),
            "balance": .number(150_000),
            "parent_amount": .number(20_000),
            "sort_order": .number(16_384),
        ]
        #expect(try RuleFormulaEvaluator.evaluate("=amount", context: context(fields)) == .number(-42.5))
        #expect(try RuleFormulaEvaluator.evaluate("=balance", context: context(fields)) == .number(1_500))
        #expect(try RuleFormulaEvaluator.evaluate("=parent_amount * 0.5", context: context(fields)) == .number(100))
        // Not money: read as stored.
        #expect(try RuleFormulaEvaluator.evaluate("=sort_order", context: context(fields)) == .number(16_384))
        // INTEGER_TO_AMOUNT now divides an amount again, as it does upstream.
        #expect(
            try RuleFormulaEvaluator.evaluate("=INTEGER_TO_AMOUNT(parent_amount) * 0.5", context: context(fields))
                == .number(1)
        )
    }

    @Test func balanceOfReadsAmountsAndMissingLiteralsAreZero() throws {
        let balances = context([:], balances: [
            "Savings": 50_000,
            "550e8400-e29b-41d4-a716-446655440000": 1_200,
        ])
        #expect(try RuleFormulaEvaluator.evaluate(#"=BALANCE_OF("Savings") + 100"#, context: balances) == .number(600))
        #expect(
            try RuleFormulaEvaluator.evaluate(#"=BALANCE_OF("550e8400-e29b-41d4-a716-446655440000")"#, context: balances)
                == .number(12)
        )
        #expect(try RuleFormulaEvaluator.evaluate(#"=BALANCE_OF("Unknown")"#, context: balances) == .number(0))
    }

    @Test func amountToIntegerIsOneJavaScriptRound() throws {
        #expect(try RuleFormulaEvaluator.amountToInteger(-42.5) == -4_250)
        #expect(try RuleFormulaEvaluator.amountToInteger(0.125) == 13)
        // No intermediate rounding to cents: 1.005 * 100 is 100.49999999999999.
        #expect(try RuleFormulaEvaluator.amountToInteger(1.005) == 100)
        #expect(throws: RuleFormulaEvaluator.EvaluationError.outOfRange) {
            try RuleFormulaEvaluator.amountToInteger(.infinity)
        }
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
