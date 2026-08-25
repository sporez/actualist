import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetCurrencyPreferenceTests {
    @Test func missingPreferencesTableDefaultsToUSD() async throws {
        let fixtureURL = try LocalFirstActualStoreTests().makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let currency = try await database.fetchBudgetCurrency()
        #expect(currency == .usd)
    }

    @Test func readsYenAndHideFractionFromPreferences() async throws {
        let fixtureURL = try LocalFirstActualStoreTests().makeSQLiteFixture(extraSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('defaultCurrencyCode', 'jpy');
            INSERT INTO preferences VALUES ('hideFraction', 'true');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let currency = try await database.fetchBudgetCurrency()
        #expect(currency.code == "JPY")
        #expect(currency.decimalPlaces == 0)
        #expect(currency.hideFraction)
    }

    @Test func emptyCurrencyCodeDefaultsToUSD() async throws {
        let fixtureURL = try LocalFirstActualStoreTests().makeSQLiteFixture(extraSQL: """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('defaultCurrencyCode', '');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        #expect(try await database.fetchBudgetCurrency() == .usd)
    }

    @Test func templateEngineScalesYenGoalAmountsWithoutTimesOneHundred() throws {
        let engine = BudgetTemplateEngine(currency: .jpy)
        #expect(try engine.amountToMinorUnits(1_234) == 1_234)
        #expect(try engine.amountToMinorUnits(12.34) == 12)
    }

    @Test func ruleAmountRoundTripsYenAndDollars() {
        let yen = RuleEditorDraftState.amountValue(from: "1234", currency: .jpy)
        #expect(RuleEditorDraftState.amountDisplayText(yen, currency: .jpy) == "1234")
        #expect(RuleEditorDraftState.minorUnits(in: yen) == 1_234)

        let dollars = RuleEditorDraftState.amountValue(from: "12.34", currency: .usd)
        #expect(RuleEditorDraftState.minorUnits(in: dollars) == 1_234)
    }

    @Test func shortcutMoneyUsesBudgetScaleNotDeviceLocale() throws {
        #expect(try ShortcutMoney.minorUnits(from: Decimal(1_234), currency: .jpy) == 1_234)
        #expect(try ShortcutMoney.minorUnits(from: Decimal(string: "12.34")!, currency: .usd) == 1_234)
        let yen = ShortcutMoney.intentAmount(minorUnits: 1_234, currency: .jpy)
        #expect(yen.amount == Decimal(1_234))
        #expect(yen.currencyCode == "JPY")
    }

    @Test func privacySamplesFollowCurrencyScale() {
        let yen = PrivacyDisplay.amount(1, seed: "transaction", currency: .jpy)
        #expect(yen == PrivacyDisplay.amount(1, seed: "transaction", currency: .jpy))
        #expect((4...900).contains(abs(yen)))

        let dollars = PrivacyDisplay.amount(1, seed: "transaction", currency: .usd)
        #expect(abs(dollars) >= 400)
        #expect(abs(dollars) % 100 == dollars.magnitude % 100)
    }
}
