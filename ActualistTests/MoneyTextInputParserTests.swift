import Foundation
import Testing
@testable import Actualist

/// Pins the literal result of every editable-money parser, including the
/// differences between them, so they can share one owner without drifting.
@Suite("Money text input parsers")
struct MoneyTextInputParserTests {
    private static let bhd = BudgetCurrency(code: "BHD", decimalPlaces: 3, hideFraction: false)
    private static let cases: [(String, String, BudgetCurrency)] = {
        let en = "en_US", de = "de_DE", fr = "fr_FR"
        var rows: [(String, String, BudgetCurrency)] = []
        for text in ["1.005", "1.00", "1", ".5", "-0", "-12.34", "(12.34)", "", "  ", "abc", "12a",
                     "90000000000000.00", "90000000000000.01", "92233720368547758.07", "999999999999999999999999999999"] {
            rows.append((en, text, .usd))
        }
        rows.append((en, "1,234.56", .usd))
        rows.append((de, "1.234,56", .usd))
        rows.append((de, "12,345", .usd))
        rows.append((fr, "1 234,56", .usd))
        rows.append((fr, "1\u{202F}234,56", .usd))
        rows.append((fr, "1\u{00A0}234,56", .usd))
        for text in ["1.5", "100", "-0", "1.0", "0.4"] { rows.append((en, text, .jpy)) }
        for text in ["1.234", "1.2345", "1.5"] { rows.append((en, text, bhd)) }
        for text in ["1.005", "12.34"] { rows.append((en, text, .none)) }
        return rows
    }()

    private static func hold(_ text: String, _ locale: Locale, _ currency: BudgetCurrency) -> String {
        shown(BudgetHoldAmountInput.amount(from: text, available: Int.max, currency: currency, locale: locale))
    }

    private static func schedule(_ text: String, _ locale: Locale, _ currency: BudgetCurrency) -> String {
        var draft = ScheduleEditorDraft(todayDayID: "2026-09-28")
        draft.amountMode = .exact
        draft.amountSign = .deposit
        draft.amountText = text
        return switch draft.amountDraft(currency: currency, locale: locale) {
        case .exact(let value): "\(value)"
        default: "nil"
        }
    }

    private static func template(_ text: String, _ currency: BudgetCurrency) -> String {
        shown(BudgetTemplateAmountInput.parseAmount(text, currency: currency))
    }

    private static func reconciliation(_ text: String, _ locale: Locale, _ currency: BudgetCurrency) -> String {
        switch AccountReconciliationAmountInput(text: text).minorUnits(currency: currency, locale: locale) {
        case .success(let value): "\(value)"
        case .failure(let error): "\(error)"
        }
    }

    private static func shown<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    /// H = hold (rejects extra digits), S = schedule (rounds), T = template
    /// (POSIX grammar, rounds, display units), R = reconciliation (own errors).
    @Test func parsersKeepTheirResults() {
        var actual: [String] = []
        for (id, text, currency) in Self.cases {
            let locale = Locale(identifier: id)
            let shownText = text
                .replacingOccurrences(of: "\u{202F}", with: "<NNBSP>")
                .replacingOccurrences(of: "\u{00A0}", with: "<NBSP>")
            let key = "\(currency.code)/\(currency.decimalPlaces)|\(id)|\(shownText.debugDescription)"
            actual.append("\(key) | H=\(Self.hold(text, locale, currency)) | S=\(Self.schedule(text, locale, currency)) | T=\(Self.template(text, currency)) | R=\(Self.reconciliation(text, locale, currency))")
        }
        #expect(actual.joined(separator: "\n") == Self.expected)
    }

    private static let expected = #"""
            USD/2|en_US|"1.005" | H=nil | S=101 | T=1.01 | R=tooManyFractionDigits
            USD/2|en_US|"1.00" | H=100 | S=100 | T=1.0 | R=100
            USD/2|en_US|"1" | H=100 | S=100 | T=1.0 | R=100
            USD/2|en_US|".5" | H=50 | S=50 | T=0.5 | R=invalid
            USD/2|en_US|"-0" | H=nil | S=0 | T=0.0 | R=0
            USD/2|en_US|"-12.34" | H=nil | S=1234 | T=-12.34 | R=-1234
            USD/2|en_US|"(12.34)" | H=nil | S=nil | T=nil | R=invalid
            USD/2|en_US|"" | H=nil | S=nil | T=nil | R=empty
            USD/2|en_US|"  " | H=nil | S=nil | T=nil | R=empty
            USD/2|en_US|"abc" | H=nil | S=nil | T=nil | R=invalid
            USD/2|en_US|"12a" | H=nil | S=nil | T=nil | R=invalid
            USD/2|en_US|"90000000000000.00" | H=9000000000000000 | S=9000000000000000 | T=90000000000000.0 | R=9000000000000000
            USD/2|en_US|"90000000000000.01" | H=nil | S=9000000000000001 | T=90000000000000.02 | R=9000000000000001
            USD/2|en_US|"92233720368547758.07" | H=nil | S=9223372036854775807 | T=9.223372036854776e+16 | R=9223372036854775807
            USD/2|en_US|"999999999999999999999999999999" | H=nil | S=nil | T=nil | R=outOfRange
            USD/2|en_US|"1,234.56" | H=123456 | S=123456 | T=nil | R=123456
            USD/2|de_DE|"1.234,56" | H=123456 | S=123456 | T=nil | R=123456
            USD/2|de_DE|"12,345" | H=nil | S=1235 | T=nil | R=tooManyFractionDigits
            USD/2|fr_FR|"1 234,56" | H=123456 | S=123456 | T=nil | R=invalid
            USD/2|fr_FR|"1<NNBSP>234,56" | H=123456 | S=123456 | T=nil | R=123456
            USD/2|fr_FR|"1<NBSP>234,56" | H=123456 | S=123456 | T=nil | R=invalid
            JPY/0|en_US|"1.5" | H=nil | S=2 | T=2.0 | R=tooManyFractionDigits
            JPY/0|en_US|"100" | H=100 | S=100 | T=100.0 | R=100
            JPY/0|en_US|"-0" | H=nil | S=0 | T=0.0 | R=0
            JPY/0|en_US|"1.0" | H=1 | S=1 | T=1.0 | R=tooManyFractionDigits
            JPY/0|en_US|"0.4" | H=nil | S=0 | T=0.0 | R=tooManyFractionDigits
            BHD/3|en_US|"1.234" | H=1234 | S=1234 | T=1.234 | R=1234
            BHD/3|en_US|"1.2345" | H=nil | S=1235 | T=1.2349999999999999 | R=tooManyFractionDigits
            BHD/3|en_US|"1.5" | H=1500 | S=1500 | T=1.5 | R=1500
            /2|en_US|"1.005" | H=nil | S=101 | T=1.01 | R=tooManyFractionDigits
            /2|en_US|"12.34" | H=1234 | S=1234 | T=12.34 | R=1234
            """#
}
