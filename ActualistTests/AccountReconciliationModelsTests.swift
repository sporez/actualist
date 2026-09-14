import Foundation
import Testing
@testable import Actualist

struct AccountReconciliationModelsTests {
    @Test func calculationPreservesSignedDifferenceAndEligibility() {
        let positive = AccountReconciliationCalculation(targetBalance: 15_000, clearedBalance: 12_500)
        let negative = AccountReconciliationCalculation(targetBalance: -20_000, clearedBalance: -17_000)
        let zero = AccountReconciliationCalculation(targetBalance: 4_200, clearedBalance: 4_200)

        #expect(positive.difference == 2_500)
        #expect(positive.canCreateAdjustment)
        #expect(!positive.canLockTransactions)
        #expect(negative.difference == -3_000)
        #expect(negative.canCreateAdjustment)
        #expect(zero.isBalanced)
        #expect(zero.canLockTransactions)
        #expect(!zero.canCreateAdjustment)
    }

    @Test func calculationFailsClosedOnIntegerOverflow() {
        let calculation = AccountReconciliationCalculation(
            targetBalance: .max,
            clearedBalance: -1
        )

        #expect(calculation.difference == nil)
        #expect(!calculation.isBalanced)
        #expect(!calculation.canCreateAdjustment)
        #expect(!calculation.canLockTransactions)
    }

    @Test func inputParsesSignedTwoZeroAndThreeDecimalCurrencies() {
        #expect(
            AccountReconciliationAmountInput(text: "+123.45")
                .minorUnits(currency: .usd, locale: Locale(identifier: "en_US")) == .success(12_345)
        )
        #expect(
            AccountReconciliationAmountInput(text: "-123")
                .minorUnits(currency: .jpy, locale: Locale(identifier: "ja_JP")) == .success(-123)
        )
        let threeDecimal = BudgetCurrency(code: "BHD", decimalPlaces: 3, hideFraction: false)
        #expect(
            AccountReconciliationAmountInput(text: "1.234")
                .minorUnits(currency: threeDecimal, locale: Locale(identifier: "en_US")) == .success(1_234)
        )
    }

    @Test func inputUsesLocaleSeparatorsWithoutGuessingExtraPrecision() {
        let german = Locale(identifier: "de_DE")
        #expect(
            AccountReconciliationAmountInput(text: "1.234,56")
                .minorUnits(currency: .usd, locale: german) == .success(123_456)
        )
        #expect(
            AccountReconciliationAmountInput(text: "12,345")
                .minorUnits(currency: .usd, locale: german) == .failure(.tooManyFractionDigits)
        )
    }

    @Test func inputRejectsEmptyJunkOverflowAndFractionForZeroDecimalCurrency() {
        #expect(AccountReconciliationAmountInput().minorUnits(currency: .usd) == .failure(.empty))
        #expect(AccountReconciliationAmountInput(text: "--1").minorUnits(currency: .usd) == .failure(.invalid))
        #expect(AccountReconciliationAmountInput(text: ".50").minorUnits(currency: .usd) == .failure(.invalid))
        #expect(
            AccountReconciliationAmountInput(text: "1.0")
                .minorUnits(currency: .jpy, locale: Locale(identifier: "en_US")) == .failure(.tooManyFractionDigits)
        )
        #expect(
            AccountReconciliationAmountInput(text: "999999999999999999999999999999")
                .minorUnits(currency: .usd, locale: Locale(identifier: "en_US")) == .failure(.outOfRange)
        )
    }

    @Test func inputFormatsAnExistingMinorUnitTarget() {
        let input = AccountReconciliationAmountInput(minorUnits: -12_345, currency: .usd)
        #expect(input.text == "-123.45")
    }

    @Test func snapshotConvertsMillisecondsToDate() throws {
        let snapshot = AccountReconciliationSnapshot(
            accountID: "checking",
            accountName: "Checking",
            workingBalance: 0,
            clearedBalance: 0,
            lastSyncedBalance: nil,
            lastReconciledMilliseconds: 1_700_000_000_500,
            capability: .available
        )
        let date = try #require(snapshot.lastReconciledAt)
        #expect(date.timeIntervalSince1970 == 1_700_000_000.5)
    }
}
