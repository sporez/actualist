import Foundation
import Testing
@testable import Actualist

@Suite("Budget template amount input")
struct BudgetTemplateAmountInputTests {
    @Test(arguments: [BudgetCurrency.usd, .jpy, .none, .catalog(code: "USD", hideFraction: true)])
    func nativeMoneyFormatKeepsEditingPrecision(currency: BudgetCurrency) {
        let fullPrecision = BudgetCurrency.catalog(code: currency.code)
        let minor = currency.decimalPlaces == 0 ? -1_400 : -140_025
        let amount = fullPrecision.displayAmount(fromMinorUnits: minor)
        let formatted = amount.formatted(BudgetTemplateMoneyFormat(currency: currency, locale: .current))
        #expect(formatted == fullPrecision.formatted(minor))
        #expect(BudgetTemplateAmountInput.formatAmount(-1400.25, currency: currency)
            == (currency.decimalPlaces == 0 ? "-1400" : "-1400.25"))
        #expect(BudgetTemplateAmountInput.numericValue("NaN") == nil)
    }

    @Test func moneyProjectionCoversAmountsAndOnlyFixedAdjustments() {
        let now = BudgetTemplateCalendar.validatedDate("2026-09-04")!
        let drafts: [BudgetTemplateDraft] = [
            .monthlyFixed(amount: 1400.25, now: now),
            .dateTarget(amount: 1400.25, now: now),
            .balanceLimit(amount: 1400.25),
            .goal(amount: 1400.25)
        ]
        for draft in drafts {
            #expect(BudgetTemplateEditorInputInterpreter.monetaryAmount(for: .amount, draft: draft) == 1400.25)
            #expect(BudgetTemplateEditorInputInterpreter.monetaryAmount(for: .priority, draft: draft) == nil)
        }
        for draft: BudgetTemplateDraft in [
            .average(adjustment: .fixed(-12.5)),
            .schedule(adjustment: .fixed(-12.5))
        ] {
            #expect(BudgetTemplateEditorInputInterpreter.monetaryAmount(for: .adjustment, draft: draft) == -12.5)
            let percentage = draft.updatingModifierAdjustment(.percent(-12.5))
            #expect(BudgetTemplateEditorInputInterpreter.monetaryAmount(for: .adjustment, draft: percentage) == nil)
            #expect(BudgetTemplateEditorInputInterpreter.text(for: .adjustment, draft: percentage, currency: .usd) == "12.5")
        }
    }

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
