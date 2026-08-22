import AppIntents
import Foundation
import Testing
@testable import Actualist

struct ShortcutMoneyTests {
    @Test func convertsMinorUnitsToIntentCurrencyAmount() {
        let amount = ShortcutMoney.intentAmount(minorUnits: 12_345)
        #expect(amount.amount == Decimal(string: "123.45"))
        #expect(amount.currencyCode == ShortcutMoney.currencyCode)
    }

    @Test func convertsNegativeMinorUnitsToIntentCurrencyAmount() {
        let amount = ShortcutMoney.intentAmount(minorUnits: -50)
        #expect(amount.amount == Decimal(string: "-0.50"))
    }

    @Test func convertsExactDecimalToMinorUnits() throws {
        #expect(try ShortcutMoney.minorUnits(from: Decimal(string: "12.50")!) == 1_250)
        #expect(try ShortcutMoney.minorUnits(from: Decimal(string: "12.5")!) == 1_250)
        #expect(try ShortcutMoney.minorUnits(from: Decimal(string: "-12.50")!) == -1_250)
        #expect(try ShortcutMoney.minorUnits(from: Decimal(0)) == 0)
    }

    @Test func roundsDecimalToNearestCent() throws {
        #expect(try ShortcutMoney.minorUnits(from: Decimal(string: "12.555")!) == 1_256)
        #expect(try ShortcutMoney.minorUnits(from: Decimal(string: "12.554")!) == 1_255)
        #expect(try ShortcutMoney.minorUnits(from: Decimal(string: "-12.555")!) == -1_256)
    }

    @Test func rejectsNonFiniteDecimals() {
        #expect(throws: ShortcutsError.amountInvalid) {
            _ = try ShortcutMoney.minorUnits(from: Decimal.nan)
        }
        #expect(throws: ShortcutsError.amountInvalid) {
            _ = try ShortcutMoney.minorUnits(from: Decimal.greatestFiniteMagnitude)
        }
    }

    @Test func convertsIntentCurrencyAmountToMinorUnits() throws {
        let amount = IntentCurrencyAmount(
            amount: Decimal(string: "20.00")!,
            currencyCode: ShortcutMoney.currencyCode
        )
        #expect(try ShortcutMoney.minorUnits(from: amount) == 2_000)
    }

    @Test func usesLocaleCurrencyCode() {
        #expect(!ShortcutMoney.currencyCode.isEmpty)
    }
}
