import Foundation
import Testing
@testable import Actualist

/// Pins the sample-values (privacy) text each money site shows. Expected
/// strings are literals captured from the generator, not recomputed.
struct PrivacyMoneySiteGoldenTests {
    @Test func historyMoneyTextMasksWithGoldenValue() {
        #expect(HistoryRowPresentation.moneyText(
            500, seed: "act-current-cat", currency: .usd, privacyEnabled: true) == "$276.05")
        #expect(HistoryRowPresentation.moneyText(
            500, seed: "act-current-cat", currency: .usd, privacyEnabled: false) == "$5.00")
    }

    @Test func moveMoneyDisplayMasksWithGoldenValues() {
        let display = BudgetMoveMoneyDisplay(isPrivacyModeEnabled: true, currency: .usd)
        let plain = BudgetMoveMoneyDisplay(isPrivacyModeEnabled: false, currency: .usd)
        let draft = BudgetMoveMoneyDraft(focusedCategoryID: "cat1", focusedCategoryName: "Food", focusedAvailable: 1_000)
        let allocation = BudgetMoveMoneyAllocation(id: "a1", destination: .toBudget, amount: 700)
        let option = BudgetMoveMoneyDestinationOption(
            id: "o1", title: "Fun", amount: 900, valueText: "$9.00", destination: .toBudget)
        #expect(display.headerAmountText(draft, amount: 500) == "$292.10")
        #expect(display.amountText(draft, amount: 500) == "$96.53")
        #expect(display.counterpartyAvailableText(draft, amount: -300) == "-$624.45")
        #expect(display.allocationAmountText(allocation) == "$772.04")
        #expect(display.optionValueText(option) == "$278.65")
        #expect(plain.headerAmountText(draft, amount: 500) == "$5.00")
        #expect(plain.optionValueText(option) == "$9.00")
    }

    @Test func templateSummaryMasksAmountWithGoldenValue() {
        let draft = BudgetTemplateDraft.monthlyFixed(amount: 100)
        #expect(BudgetTemplateSummary.label(draft, currency: .usd, randomized: true, seed: "tpl-seed") == "$409.02/mo")
        #expect(BudgetTemplateSummary.label(draft, currency: .usd, randomized: false, seed: "tpl-seed") == "$100.00/mo")
    }

    @Test func templateContributionTextMasksWithGoldenValue() {
        #expect(BudgetTemplateAmountInput.contributionText(
            minorUnits: 2_500, currency: .usd, randomized: true, seed: "tpl-c") == "$309.15")
        #expect(BudgetTemplateAmountInput.contributionText(
            minorUnits: 2_500, currency: .usd, randomized: false, seed: "tpl-c") == "$25.00")
        #expect(BudgetTemplateAmountInput.contributionText(
            minorUnits: nil, currency: .usd, randomized: true, seed: "tpl-c") == "—")
        #expect(BudgetTemplateAmountInput.contributionText(
            minorUnits: nil, currency: .usd, randomized: false, seed: "tpl-c") == "—")
    }

    @Test func commandReviewAmountTextMasksWithGoldenValue() {
        #expect(TransactionCommandReviewFormatting.amountText(
            -500, seed: "s", currency: .usd, isPrivacyModeEnabled: true) == "-$125.64")
        #expect(TransactionCommandReviewFormatting.amountText(
            -500, seed: "s", currency: .usd, isPrivacyModeEnabled: false) == "-$5.00")
    }

    /// Seeds and ranges used by `RuleMatchPreview` and the Accounts list rows.
    @Test func ruleMatchAndAccountSeedsMatchGoldenValues() {
        #expect(PrivacyDisplay.money(1_234, seed: "rule-match-t1", currency: .usd, maximumDollars: 275) == "$93.25")
        #expect(PrivacyDisplay.money(-1_234, seed: "rule-match-t1", currency: .usd, maximumDollars: 275) == "-$93.25")
        #expect(PrivacyDisplay.money(250_000, seed: "account-balance-a1", currency: .usd, maximumDollars: 15_000) == "$14,289.68")
        #expect(PrivacyDisplay.money(nil, seed: "account-balance-a1", currency: .usd, maximumDollars: 15_000) == "$14,289.68")
        #expect(PrivacyDisplay.money(-9, seed: "account-balance-a1", currency: .usd, maximumDollars: 15_000) == "-$14,289.68")
        #expect(PrivacyDisplay.money(1, seed: "account-section-Budget-a1-a2", currency: .usd, maximumDollars: 15_000) == "$11,642.72")
    }
}
