import Foundation
import Testing
@testable import Actualist

struct BudgetCurrencyTests {
    @Test func catalogPreservesEmptyCodesAsCurrencyNeutral() {
        #expect(BudgetCurrency.catalog(code: "") == .none)
        #expect(BudgetCurrency.catalog(code: "  ") == .none)
        #expect(BudgetCurrency.catalog(code: "usd").code == "USD")
        #expect(BudgetCurrency.catalog(code: "usd").decimalPlaces == 2)
    }

    @Test func catalogUsesZeroDecimalsForYenAndWon() {
        #expect(BudgetCurrency.catalog(code: "JPY") == .jpy)
        #expect(BudgetCurrency.catalog(code: "krw") == .krw)
        #expect(BudgetCurrency.catalog(code: "GBP").decimalPlaces == 2)
        #expect(BudgetCurrency.catalog(code: "GBP").code == "GBP")
    }

    @Test func catalogKeepsUnknownCodesAtTwoDecimals() {
        let currency = BudgetCurrency.catalog(code: "XXX")
        #expect(currency.code == "XXX")
        #expect(currency.decimalPlaces == 2)
    }

    @Test func catalogPreservesHideFraction() {
        #expect(BudgetCurrency.catalog(code: "USD", hideFraction: true).hideFraction)
        #expect(!BudgetCurrency.catalog(code: "JPY", hideFraction: false).hideFraction)
    }

    @Test func neutralCurrencyAcceptsSameScaleCodesOnly() {
        #expect(BudgetCurrency.none.accepts("USD"))
        #expect(BudgetCurrency.none.accepts("cad"))
        #expect(BudgetCurrency.none.accepts("GBP"))
        #expect(!BudgetCurrency.none.accepts("JPY"))
        #expect(!BudgetCurrency.none.accepts("KRW"))
        #expect(!BudgetCurrency.none.accepts(""))
        #expect(!BudgetCurrency.none.accepts("  "))
        #expect(BudgetCurrency.usd.accepts("usd"))
        #expect(!BudgetCurrency.usd.accepts("CAD"))
        #expect(!BudgetCurrency.usd.accepts("JPY"))
        #expect(!BudgetCurrency.jpy.accepts("USD"))
        #expect(BudgetCurrency.jpy.accepts("jpy"))
    }

    @Test func convertsTwoDecimalDisplayAmounts() {
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Decimal(string: "12.34")!) == 1_234)
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Decimal(string: "-12.34")!) == -1_234)
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Decimal(string: "12.3")!) == 1_230)
        #expect(BudgetCurrency.usd.displayAmount(fromMinorUnits: 1_234) == Decimal(string: "12.34"))
        #expect(BudgetCurrency.usd.displayAmount(fromMinorUnits: -50) == Decimal(string: "-0.5"))
    }

    @Test func convertsZeroDecimalDisplayAmountsWithoutRescaling() {
        #expect(BudgetCurrency.jpy.minorUnits(fromDisplay: Decimal(1_234)) == 1_234)
        #expect(BudgetCurrency.jpy.minorUnits(fromDisplay: Decimal(string: "1234.4")!) == 1_234)
        #expect(BudgetCurrency.jpy.minorUnits(fromDisplay: Decimal(string: "1234.5")!) == 1_235)
        #expect(BudgetCurrency.jpy.displayAmount(fromMinorUnits: 1_234) == Decimal(1_234))
    }

    @Test func convertsArbitraryDecimalPlaces() {
        let dinar = BudgetCurrency(code: "KWD", decimalPlaces: 3, hideFraction: false)
        #expect(dinar.minorUnits(fromDisplay: Decimal(string: "1.234")!) == 1_234)
        #expect(dinar.displayAmount(fromMinorUnits: 1_234) == Decimal(string: "1.234"))
    }

    @Test func roundsHalfAwayFromZero() {
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Decimal(string: "12.345")!) == 1_235)
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Decimal(string: "12.344")!) == 1_234)
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Decimal(string: "-12.345")!) == -1_235)
    }

    @Test func rejectsNonFiniteAndUnrepresentableAmounts() {
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Decimal.nan) == nil)
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Decimal.greatestFiniteMagnitude) == nil)
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Double.nan) == nil)
        #expect(BudgetCurrency.usd.minorUnits(fromDisplay: Double.infinity) == nil)
    }

    @Test func removeFractionRoundsToWholeCurrencyUnits() {
        #expect(BudgetCurrency.usd.removingFraction(fromMinorUnits: 12_345) == 12_300)
        #expect(BudgetCurrency.usd.removingFraction(fromMinorUnits: 12_350) == 12_400)
        #expect(BudgetCurrency.usd.removingFraction(fromMinorUnits: -12_350) == -12_400)
        #expect(BudgetCurrency.jpy.removingFraction(fromMinorUnits: 1_234) == 1_234)
    }

    @Test func moneyOverloadsUseBudgetScaleAndCode() {
        #expect(Money(minorUnits: 1_234).decimalValue(using: .usd) == Decimal(string: "12.34"))
        #expect(Money(minorUnits: 1_234).decimalValue(using: .jpy) == Decimal(1_234))

        let neutral = Money(minorUnits: 1_234).formatted(using: .none)
        #expect(!neutral.contains("$"))
        #expect(!neutral.localizedCaseInsensitiveContains("USD"))

        let yen = Money(minorUnits: 1_234).formatted(using: .jpy)
        #expect(!yen.contains("."))
        #expect(yen.contains("1,234") || yen.contains("1234"))

        let pounds = Money(minorUnits: 1_234).formatted(using: BudgetCurrency.catalog(code: "GBP"))
        #expect(!pounds.contains("$"))
        #expect(pounds.contains("12.34"))
    }
}
