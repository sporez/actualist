import Foundation
import Testing
@testable import Actualist

struct BudgetHoldAmountInputTests {
    private let locale = Locale(identifier: "en_US")

    @Test(arguments: [BudgetCurrency.usd, .none, .jpy, .catalog(code: "EUR", hideFraction: true)])
    func defaultAmountPreservesMinorUnits(_ currency: BudgetCurrency) {
        let text = BudgetHoldAmountInput.text(amount: 12_345, currency: currency, locale: locale)
        #expect(BudgetHoldAmountInput.amount(from: text, available: 12_345, currency: currency, locale: locale) == 12_345)
    }

    @Test(arguments: ["", " ", "abc", "12 dollars", "12.345", "0", "-1", "100.01", "NaN", "∞"])
    func invalidOrUnavailableAmountCannotBeSubmitted(_ text: String) {
        #expect(BudgetHoldAmountInput.amount(from: text, available: 10_000, currency: .usd, locale: locale) == nil)
    }

    @Test func partialAndAllAmountsUseCurrencyScale() {
        #expect(BudgetHoldAmountInput.amount(from: "12.34", available: 10_000, currency: .usd, locale: locale) == 1_234)
        #expect(BudgetHoldAmountInput.amount(from: "100", available: 10_000, currency: .usd, locale: locale) == 10_000)
        #expect(BudgetHoldAmountInput.amount(from: "1234", available: 10_000, currency: .jpy, locale: locale) == 1_234)
        #expect(BudgetHoldAmountInput.amount(from: "12.34", available: 10_000, currency: .jpy, locale: locale) == nil)
    }

    @Test func localeAndAvailabilityAreHonored() {
        let german = Locale(identifier: "de_DE")
        #expect(BudgetHoldAmountInput.text(amount: 1_234, currency: .usd, locale: german) == "12,34")
        #expect(BudgetHoldAmountInput.amount(from: "12,34", available: 2_000, currency: .usd, locale: german) == 1_234)
        #expect(BudgetHoldAmountInput.amount(from: "1", available: 0, currency: .usd, locale: locale) == nil)
        #expect(BudgetHoldAmountInput.amount(from: "1", available: -1, currency: .usd, locale: locale) == nil)
        #expect(BudgetHoldAmountInput.amount(from: "999999999999999999999", available: Int.max, currency: .usd, locale: locale) == nil)
    }
}
