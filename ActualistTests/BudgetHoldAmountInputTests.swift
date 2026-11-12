import Foundation
import Testing
@testable import Actualist

struct BudgetHoldAmountInputTests {
    @Test(arguments: [BudgetCurrency.usd, .none, .jpy, .catalog(code: "EUR", hideFraction: true)])
    func defaultAmountPreservesMinorUnits(_ currency: BudgetCurrency) {
        let text = BudgetHoldAmountInput.text(amount: 12_345, currency: currency)
        #expect(BudgetHoldAmountInput.amount(from: text, available: 12_345, currency: currency) == 12_345)
    }

    @Test(arguments: ["", " ", "abc", "0", "-1", "NaN", "∞", "0.00"])
    func textWithoutAPositiveAmountCannotBeSubmitted(_ text: String) {
        #expect(BudgetHoldAmountInput.amount(from: text, available: 10_000, currency: .usd) == nil)
    }

    @Test func partialAmountsUseTheBudgetsNumberFormat() {
        #expect(BudgetHoldAmountInput.amount(from: "12.34", available: 10_000, currency: .usd) == 1_234)
        #expect(BudgetHoldAmountInput.amount(from: "1234", available: 10_000, currency: .jpy) == 1_234)
        let german = BudgetCurrency.catalog(code: "EUR", numberFormat: .dotComma)
        #expect(BudgetHoldAmountInput.text(amount: 1_234, currency: german) == "12,34")
        #expect(BudgetHoldAmountInput.amount(from: "12,34", available: 2_000, currency: german) == 1_234)
        #expect(BudgetHoldAmountInput.amount(from: "1.234,56", available: 200_000, currency: german) == 123_456)
    }

    @Test func amountAboveAvailableIsHeldAtAvailable() {
        #expect(BudgetHoldAmountInput.amount(from: "100.01", available: 10_000, currency: .usd) == 10_000)
        #expect(BudgetHoldAmountInput.amount(from: "1000", available: 10_000, currency: .usd) == 10_000)
        #expect(BudgetHoldAmountInput.exceedsAvailable(text: "100.01", available: 10_000, currency: .usd))
        #expect(!BudgetHoldAmountInput.exceedsAvailable(text: "100", available: 10_000, currency: .usd))
        #expect(!BudgetHoldAmountInput.exceedsAvailable(text: "abc", available: 10_000, currency: .usd))
    }

    @Test func nothingToHoldAndHugeValuesAreRefused() {
        #expect(BudgetHoldAmountInput.amount(from: "1", available: 0, currency: .usd) == nil)
        #expect(BudgetHoldAmountInput.amount(from: "1", available: -1, currency: .usd) == nil)
        #expect(BudgetHoldAmountInput.amount(from: "999999999999999999999", available: Int.max, currency: .usd) == nil)
    }

    @Test func digitsShiftIntoTheDecimalsUnlessFractionsAreHidden() {
        #expect(BudgetHoldAmountInput.fieldText(typed: "1", currency: .usd) == "0.01")
        #expect(BudgetHoldAmountInput.fieldText(typed: "0.015", currency: .usd) == "0.15")
        #expect(BudgetHoldAmountInput.fieldText(typed: "1005", currency: .usd) == "10.05")
        #expect(BudgetHoldAmountInput.fieldText(typed: "", currency: .usd) == "")
        #expect(BudgetHoldAmountInput.fieldText(typed: "1005", currency: .jpy) == "1005")
        #expect(BudgetHoldAmountInput.fieldText(typed: "10.5", currency: .catalog(code: "USD", hideFraction: true)) == "10.5")
        let german = BudgetCurrency.catalog(code: "EUR", numberFormat: .dotComma)
        #expect(BudgetHoldAmountInput.fieldText(typed: "1005", currency: german) == "10,05")
    }
}
