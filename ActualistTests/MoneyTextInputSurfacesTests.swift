import Foundation
import Testing
@testable import Actualist

/// The four editable money surfaces read typed text through one owner, so they agree on
/// every entry. `MoneyInputOracleReplayTests` pins that owner to Actual's values; this
/// suite pins that Hold, the schedule editor, the template editor and reconciliation all
/// use it, with the results Actual gives.
@Suite("Money text input surfaces")
struct MoneyTextInputSurfacesTests {
    private static let dotComma = BudgetCurrency.catalog(code: "EUR", numberFormat: .dotComma)
    private static let spaceComma = BudgetCurrency.catalog(code: "EUR", numberFormat: .spaceComma)

    private static let positive: [(text: String, currency: BudgetCurrency, minorUnits: Int)] = [
        ("1.005", .usd, 100), (".5", .usd, 50), ("5.", .usd, 500), ("1,234.56", .usd, 123_456),
        ("(12.34)", .usd, 1_234), ("12a", .usd, 1_200), ("10+5", .usd, 1_500), ("2*3.5", .usd, 700),
        ("10/4", .usd, 250), ("2^3", .usd, 800), ("1 234.56", .usd, 123_456), ("$12.34", .usd, 1_234),
        ("1.5", .jpy, 2), ("2.5", .jpy, 3), ("100", .jpy, 100),
        ("1.234,56", dotComma, 123_456), ("1.005", dotComma, 100_500), ("12,5", dotComma, 1_250),
        ("1 234,56", spaceComma, 123_456), ("1\u{202F}234,56", spaceComma, 123_456), ("1.005", spaceComma, 100)
    ]
    private static let unreadable = ["", "  ", "abc", "--5", "."]

    private static func schedule(_ text: String, _ currency: BudgetCurrency) -> Int? {
        var draft = ScheduleEditorDraft(todayDayID: "2026-09-28")
        draft.amountMode = .exact
        draft.amountSign = .deposit
        draft.amountText = text
        guard case .exact(let value)? = draft.amountDraft(currency: currency) else { return nil }
        return value
    }

    private static func template(_ text: String, _ currency: BudgetCurrency) -> Int? {
        BudgetTemplateAmountInput.parseAmount(text, currency: currency).flatMap {
            currency.minorUnits(fromDisplay: $0)
        }
    }

    private static func reconciliation(_ text: String, _ currency: BudgetCurrency) -> Int? {
        try? AccountReconciliationAmountInput(text: text).minorUnits(currency: currency).get()
    }

    private static func hold(_ text: String, _ currency: BudgetCurrency) -> Int? {
        BudgetHoldAmountInput.amount(from: text, available: Int.max, currency: currency)
    }

    @Test func everySurfaceReadsTypedAmountsAsActualDoes() {
        for (text, currency, expected) in Self.positive {
            let label = "\(text.debugDescription) \(currency.code)/\(currency.numberFormat.rawValue)"
            #expect(Self.schedule(text, currency) == expected, "schedule \(label)")
            #expect(Self.template(text, currency) == expected, "template \(label)")
            #expect(Self.reconciliation(text, currency) == expected, "reconciliation \(label)")
            #expect(Self.hold(text, currency) == expected, "hold \(label)")
        }
    }

    @Test func everySurfaceRefusesUnreadableText() {
        for text in Self.unreadable {
            #expect(Self.schedule(text, .usd) == nil, "schedule \(text.debugDescription)")
            #expect(Self.template(text, .usd) == nil, "template \(text.debugDescription)")
            #expect(Self.reconciliation(text, .usd) == nil, "reconciliation \(text.debugDescription)")
            #expect(Self.hold(text, .usd) == nil, "hold \(text.debugDescription)")
        }
    }

    @Test func signedTextKeepsItsSignWhereTheSurfaceAllowsOne() {
        #expect(Self.reconciliation("-12.34", .usd) == -1_234)
        #expect(Self.reconciliation("\u{2212}12.34", .usd) == -1_234)
        #expect(Self.template("-12.34", .usd) == -1_234)
        #expect(Self.schedule("-12.34", .usd) == 1_234)
        #expect(Self.hold("-12.34", .usd) == nil)
    }

    @Test func textWrittenForAnAmountReadsBackInEveryNumberFormat() {
        for format in ActualNumberFormat.allCases {
            for currency in [BudgetCurrency.catalog(code: "USD", numberFormat: format), .catalog(code: "JPY", numberFormat: format)] {
                for amount in [0, 5, 100, 123_456, -123_456, 100_000_033] {
                    let text = BudgetMoneyInputFormat.editText(minorUnits: amount, currency: currency)
                    #expect(Self.reconciliation(text, currency) == amount, "\(text) \(format.rawValue) \(currency.code)")
                }
            }
        }
    }
}
