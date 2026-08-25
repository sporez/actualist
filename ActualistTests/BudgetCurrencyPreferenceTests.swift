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

    @Test func privacySamplesFollowCurrencyScale() {
        let yen = PrivacyDisplay.amount(1, seed: "transaction", currency: .jpy)
        #expect(yen == PrivacyDisplay.amount(1, seed: "transaction", currency: .jpy))
        #expect((4...900).contains(abs(yen)))

        let dollars = PrivacyDisplay.amount(1, seed: "transaction", currency: .usd)
        #expect(abs(dollars) >= 400)
        #expect(abs(dollars) % 100 == dollars.magnitude % 100)
    }
}
