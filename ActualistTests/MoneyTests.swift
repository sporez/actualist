import Foundation
import Testing
@testable import Actualist

struct MoneyTests {
    @Test func incomeAmountHighlightingRequiresAnEnabledPreferenceAndPositiveAmount() {
        #expect(TransactionAmountPresentation.shouldHighlightAsIncome(amount: 1, preferenceEnabled: true))
        #expect(!TransactionAmountPresentation.shouldHighlightAsIncome(amount: 0, preferenceEnabled: true))
        #expect(!TransactionAmountPresentation.shouldHighlightAsIncome(amount: -1, preferenceEnabled: true))
        #expect(!TransactionAmountPresentation.shouldHighlightAsIncome(amount: 1, preferenceEnabled: false))
        #expect(!TransactionAmountPresentation.shouldHighlightAsIncome(amount: nil, preferenceEnabled: true))
    }

    @Test func formatsActualMinorUnitsAsCurrency() {
        #expect(123456.actualMoney.formatted(using: .usd).contains("1,234.56"))
    }

    @Test func privacyDisplayUsesStableGenericMoneyAndNames() {
        #expect(PrivacyDisplay.name(for: .account, seed: "checking") == PrivacyDisplay.name(for: .account, seed: "checking"))
        #expect(PrivacyDisplay.amount(-12_345, seed: "transaction") < 0)
        #expect(PrivacyDisplay.amount(12_345, seed: "transaction") > 0)
        #expect(PrivacyDisplay.money(12_345, seed: "transaction").contains("$"))
    }

    /// Expected values are hard-coded from the FNV-based generator so a change
    /// to the seed hashing or ranges cannot hide behind a same-function check.
    @Test func privacyDisplayNamesMatchGoldenValues() {
        #expect(PrivacyDisplay.name(for: .account, seed: "acct-1") == "Cash 82")
        #expect(PrivacyDisplay.name(for: .category, seed: "cat-1") == "Dining")
        #expect(PrivacyDisplay.name(for: .payee, seed: "payee-1") == "Vendor")
        #expect(PrivacyDisplay.name(for: .budget, seed: "b-1") == "Sample Budget 56")
    }

    @Test func privacyDisplayAmountsMatchGoldenValues() {
        #expect(PrivacyDisplay.amount(12_345, seed: "seed-a") == 24_479)
        #expect(PrivacyDisplay.amount(-12_345, seed: "seed-a") == -24_479)
        #expect(PrivacyDisplay.amount(0, seed: "seed-a") == 24_479)
        #expect(PrivacyDisplay.amount(nil, seed: "seed-c") == 59_029)
        #expect(PrivacyDisplay.amount(500, seed: "seed-b", maximumDollars: 15_000) == 979_554)
        #expect(PrivacyDisplay.amount(-500, seed: "seed-b", maximumDollars: 275) == -10_354)
        #expect(PrivacyDisplay.amount(7, seed: "seed-c", maximumDollars: 5) == 429)
        #expect(PrivacyDisplay.amount(12_345, seed: "seed-a", currency: .jpy) == 244)
        #expect(PrivacyDisplay.amount(-12_345, seed: "seed-a", currency: .jpy) == -244)
        #expect(PrivacyDisplay.amount(500, seed: "seed-b", currency: .jpy, maximumDollars: 15_000) == 9_795)
    }

    @Test func privacyDisplayMoneyMatchesGoldenStrings() {
        #expect(PrivacyDisplay.money(12_345, seed: "seed-a") == "$244.79")
        #expect(PrivacyDisplay.money(-12_345, seed: "seed-a") == "-$244.79")
        #expect(PrivacyDisplay.money(0, seed: "seed-a") == "$244.79")
        #expect(PrivacyDisplay.money(nil, seed: "seed-c") == "$590.29")
        #expect(PrivacyDisplay.money(500, seed: "seed-b", maximumDollars: 15_000) == "$9,795.54")
        #expect(PrivacyDisplay.money(-500, seed: "seed-b", maximumDollars: 275) == "-$103.54")
        #expect(PrivacyDisplay.money(12_345, seed: "seed-a", currency: .jpy) == "¥244")
        #expect(PrivacyDisplay.money(-12_345, seed: "seed-a", currency: .jpy) == "-¥244")
        #expect(PrivacyDisplay.money(500, seed: "seed-b", currency: .jpy, maximumDollars: 15_000) == "¥9,795")
    }

    @Test func budgetSyncIDPrefersGroupID() throws {
        let json = """
        {
          "id": "friendly-name",
          "cloudFileId": "d76ea46f-a902-48e6-a72a-a9be53de7d96",
          "groupId": "9e5a0d5b-7b6b-40d2-a752-1f7da0516288",
          "name": "Personal"
        }
        """.data(using: .utf8)!

        let budget = try JSONDecoder().decode(ActualBudget.self, from: json)
        #expect(budget.syncID == "9e5a0d5b-7b6b-40d2-a752-1f7da0516288")
    }
}
