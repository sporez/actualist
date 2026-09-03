import Foundation
import Testing
@testable import Actualist

@Suite("Budget template amount input")
struct BudgetTemplateAmountInputTests {
    @Test func parseAndFormatUseCurrencyScale() {
        #expect(BudgetTemplateAmountInput.parseAmount("400", currency: .usd) == 400)
        #expect(BudgetTemplateAmountInput.parseAmount("400.10", currency: .usd) == 400.1)
        #expect(BudgetTemplateAmountInput.parseAmount("not-a-number", currency: .usd) == nil)
        #expect(BudgetTemplateAmountInput.parseAmount("", currency: .usd) == nil)
        #expect(BudgetTemplateAmountInput.formatAmount(400, currency: .usd) == "400.00")
        #expect(BudgetTemplateAmountInput.parseAmount("250", currency: .jpy) == 250)
        #expect(BudgetTemplateAmountInput.formatAmount(250, currency: .jpy) == "250")
    }

    @Test func parseIntAndWeight() {
        #expect(BudgetTemplateAmountInput.parseInt("12") == 12)
        #expect(BudgetTemplateAmountInput.parseInt(" 3 ") == 3)
        #expect(BudgetTemplateAmountInput.parseInt("1.5") == nil)
        #expect(BudgetTemplateAmountInput.parseWeight("2") == 2)
        #expect(BudgetTemplateAmountInput.parseWeight("1.5") == 1.5)
        #expect(BudgetTemplateAmountInput.parseWeight("") == nil)
    }

    @Test func contributionTextRandomizes() {
        #expect(
            BudgetTemplateAmountInput.contributionText(
                minorUnits: nil,
                currency: .usd,
                randomized: false,
                seed: "x"
            ) == "—"
        )
        let real = BudgetCurrency.usd.formatted(12_500)
        #expect(
            BudgetTemplateAmountInput.contributionText(
                minorUnits: 12_500,
                currency: .usd,
                randomized: false,
                seed: "x"
            ) == real
        )
        let privateText = BudgetTemplateAmountInput.contributionText(
            minorUnits: 12_500,
            currency: .usd,
            randomized: true,
            seed: "x"
        )
        #expect(privateText == PrivacyDisplay.money(12_500, seed: "x", currency: .usd))
    }
}
