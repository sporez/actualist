import Foundation
import Testing
@testable import Actualist

/// Actual's amount fields decide every case. `scripts/money-input-parity` runs Actual's
/// `fromEdit`, `forEdit` and a mounted auto-decimals `AmountInput` under every number
/// format and both currency scales; the shared parser must give the same minor units.
///
/// One intended difference: Actualist refuses magnitudes above
/// `Money.maximumUserAmountMinorUnits` (and non-finite results) as `.outOfRange`, where
/// Actual returns the number and fails later when it formats it. Those cases expect
/// `.outOfRange`; see `actualistLimitCaseIDs`.
@Suite("Money input oracle replay")
struct MoneyInputOracleReplayTests {
    private static let cases = Result { try MoneyInputOracleFixture.load().cases }

    private static func currency(_ input: MoneyInputOracleFixture.Input) -> BudgetCurrency {
        BudgetCurrency(
            code: input.currencyCode,
            decimalPlaces: input.decimalPlaces,
            hideFraction: false,
            numberFormat: ActualNumberFormat(preference: input.numberFormat)
        )
    }

    /// Cases where Actual's number is outside what Actualist accepts, so `.outOfRange` is expected.
    private static func isBeyondActualistLimit(_ outcome: MoneyInputOracleFixture.Outcome) -> Bool {
        switch outcome.kind {
        case "unsafe": true
        case "integer": abs(outcome.value ?? 0) > Money.maximumUserAmountMinorUnits
        default: false
        }
    }

    private static func mismatch(
        _ result: Result<Int, MoneyInputError>,
        expected outcome: MoneyInputOracleFixture.Outcome
    ) -> String? {
        if isBeyondActualistLimit(outcome) {
            return result == .failure(.outOfRange) ? nil : "expected outOfRange, got \(result)"
        }
        switch (outcome.kind, result) {
        case ("integer", .success(let value)) where value == outcome.value:
            return nil
        case ("none", .failure(.empty)), ("none", .failure(.invalid)):
            return nil
        default:
            return "expected \(outcome.kind) \(outcome.value.map(String.init) ?? ""), got \(result)"
        }
    }

    static let actualistLimitCaseIDs: [String] = ((try? cases.get()) ?? []).compactMap { testCase in
        switch testCase.expected {
        case .fromEdit(let outcome) where isBeyondActualistLimit(outcome): testCase.id
        default: nil
        }
    }

    @Test func fixtureCoversEveryNumberFormatAndScale() throws {
        let cases = try Self.cases.get()
        #expect(cases.count == 780)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(Set(cases.map(\.input.numberFormat)).count == 5)
        #expect(Set(cases.map(\.input.decimalPlaces)) == [0, 2])
        #expect(Set(cases.map(\.mode)) == ["fromEdit", "forEdit", "autoDecimals"])
        #expect(!Self.actualistLimitCaseIDs.isEmpty)
    }

    @Test func typedAmountsMatchActualFromEdit() throws {
        var failures: [String] = []
        var replayed = 0
        for testCase in try Self.cases.get() {
            guard case .fromEdit(let outcome) = testCase.expected, let text = testCase.input.text else { continue }
            replayed += 1
            let result = BudgetMoneyInputFormat.minorUnits(text, currency: Self.currency(testCase.input))
            if let problem = Self.mismatch(result, expected: outcome) {
                failures.append("\(testCase.id) \(text.debugDescription): \(problem)")
            }
        }
        #expect(replayed == 570)
        #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(40).joined(separator: "\n"))")
    }

    /// Actual's own edit text, with its thousands separators, reads back to the amount it was made from;
    /// and the text Actualist writes for an amount reads back to it too.
    @Test func editTextRoundTripsAsActualDoes() throws {
        var failures: [String] = []
        var replayed = 0
        for testCase in try Self.cases.get() {
            guard case .forEdit(let text, let parsedBack) = testCase.expected,
                  let minorUnits = testCase.input.minorUnits else { continue }
            replayed += 1
            let currency = Self.currency(testCase.input)
            if let problem = Self.mismatch(BudgetMoneyInputFormat.minorUnits(text, currency: currency), expected: parsedBack) {
                failures.append("\(testCase.id) Actual text \(text.debugDescription): \(problem)")
            }
            let written = BudgetMoneyInputFormat.editText(minorUnits: minorUnits, currency: currency)
            if BudgetMoneyInputFormat.minorUnits(written, currency: currency) != .success(minorUnits) {
                failures.append("\(testCase.id) own text \(written.debugDescription) does not read back to \(minorUnits)")
            }
            let withoutGrouping = text.filter { $0 != currency.numberFormat.thousandsSeparator }
            if written != withoutGrouping {
                failures.append("\(testCase.id) own text \(written.debugDescription) differs from Actual's \(text.debugDescription) without grouping")
            }
        }
        #expect(replayed == 80)
        #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(40).joined(separator: "\n"))")
    }

    @Test func autoDecimalsMatchActualHoldField() throws {
        var failures: [String] = []
        var replayed = 0
        for testCase in try Self.cases.get() {
            guard case .autoDecimals(let editText, let amount, _) = testCase.expected,
                  let typed = testCase.input.text else { continue }
            replayed += 1
            let currency = Self.currency(testCase.input)
            let shown = BudgetMoneyInputFormat.autoDecimalsText(typed, currency: currency)
            var result = BudgetMoneyInputFormat.minorUnits(shown, currency: currency)
            // AmountInput reads a field with no digits as 0.
            if case .failure(let error) = result, error == .empty || error == .invalid { result = .success(0) }
            if let problem = Self.mismatch(result, expected: amount) {
                failures.append("\(testCase.id) \(typed.debugDescription): \(problem)")
            }
            // Beyond 2^53 Actual's text comes from a rounded Double, while ours keeps every digit.
            if amount.kind == "integer" {
                let withoutGrouping = editText.filter { $0 != currency.numberFormat.thousandsSeparator }
                if shown != withoutGrouping {
                    failures.append("\(testCase.id) \(typed.debugDescription): shows \(shown.debugDescription), Actual \(editText.debugDescription)")
                }
            }
        }
        #expect(replayed == 130)
        #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(40).joined(separator: "\n"))")
    }
}
