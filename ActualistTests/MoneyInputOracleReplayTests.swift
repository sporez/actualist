import Foundation
import Testing
@testable import Actualist

/// Actual's amount fields decide every case. `scripts/money-input-parity` runs Actual's
/// `fromEdit`, `forEdit` and a mounted auto-decimals `AmountInput` under every number
/// format and both currency scales; the shared parser must give the same minor units and
/// `editText` the same text. Every difference is a registered finding (OP-93, OP-94);
/// all other cases are compared exactly.
@Suite("Money input oracle replay")
struct MoneyInputOracleReplayTests {
    private static let cases = Result { try MoneyInputOracleFixture.load().cases }

    private static func currency(_ input: MoneyInputOracleFixture.Input) -> BudgetCurrency {
        BudgetCurrency(
            code: input.currencyCode,
            decimalPlaces: input.decimalPlaces,
            hideFraction: input.hideFraction ?? false,
            numberFormat: ActualNumberFormat(preference: input.numberFormat)
        )
    }

    private static func mismatch(
        _ result: Result<Int, MoneyInputError>,
        expected outcome: MoneyInputOracleFixture.Outcome
    ) -> String? {
        switch (outcome.kind, result) {
        case ("integer", .success(let value)) where value == outcome.value:
            return nil
        case ("none", .failure(.empty)), ("none", .failure(.invalid)):
            return nil
        default:
            return "expected \(outcome.kind) \(outcome.value.map(String.init) ?? outcome.repr ?? ""), got \(result)"
        }
    }

    /// OP-93: with hide-fraction on, Actual's edit text drops the cents (and a save would lose them).
    private static let hideFractionEditCaseIDs: Set<String> = [
        "for-edit-hide-fraction-comma-dot-dp2-0",
        "for-edit-hide-fraction-comma-dot-dp2-1",
        "for-edit-hide-fraction-comma-dot-dp2-2"
    ]

    /// OP-94: Actual returns an amount beyond `Money.maximumUserAmountMinorUnits` (or Infinity)
    /// and fails later when it formats it; Actualist reports `.outOfRange`.
    private static let beyondLimitCaseIDs: Set<String> = [
        "from-edit-comma-dot-dp2-48",
        "from-edit-comma-dot-dp2-50",
        "from-edit-comma-dot-dp2-54",
        "from-edit-comma-dot-dp2-55",
        "from-edit-comma-dot-dp2-56",
        "from-edit-comma-dot-dp0-48",
        "from-edit-comma-dot-dp0-50",
        "from-edit-comma-dot-dp0-55",
        "from-edit-comma-dot-dp0-56",
        "from-edit-dot-comma-dp2-48",
        "from-edit-dot-comma-dp2-50",
        "from-edit-dot-comma-dp2-54",
        "from-edit-dot-comma-dp2-55",
        "from-edit-dot-comma-dp2-56",
        "from-edit-dot-comma-dp0-48",
        "from-edit-dot-comma-dp0-50",
        "from-edit-dot-comma-dp0-55",
        "from-edit-dot-comma-dp0-56",
        "from-edit-space-comma-dp2-48",
        "from-edit-space-comma-dp2-50",
        "from-edit-space-comma-dp2-54",
        "from-edit-space-comma-dp2-55",
        "from-edit-space-comma-dp2-56",
        "from-edit-space-comma-dp0-48",
        "from-edit-space-comma-dp0-50",
        "from-edit-space-comma-dp0-55",
        "from-edit-space-comma-dp0-56",
        "from-edit-apostrophe-dot-dp2-48",
        "from-edit-apostrophe-dot-dp2-50",
        "from-edit-apostrophe-dot-dp2-54",
        "from-edit-apostrophe-dot-dp2-55",
        "from-edit-apostrophe-dot-dp2-56",
        "from-edit-apostrophe-dot-dp0-48",
        "from-edit-apostrophe-dot-dp0-50",
        "from-edit-apostrophe-dot-dp0-55",
        "from-edit-apostrophe-dot-dp0-56",
        "from-edit-comma-dot-in-dp2-48",
        "from-edit-comma-dot-in-dp2-50",
        "from-edit-comma-dot-in-dp2-54",
        "from-edit-comma-dot-in-dp2-55",
        "from-edit-comma-dot-in-dp2-56",
        "from-edit-comma-dot-in-dp0-48",
        "from-edit-comma-dot-in-dp0-50",
        "from-edit-comma-dot-in-dp0-55",
        "from-edit-comma-dot-in-dp0-56",
        "auto-decimals-comma-dot-dp2-12",
        "auto-decimals-comma-dot-dp0-12",
        "auto-decimals-dot-comma-dp2-12",
        "auto-decimals-dot-comma-dp0-12",
        "auto-decimals-space-comma-dp2-12",
        "auto-decimals-space-comma-dp0-12",
        "auto-decimals-apostrophe-dot-dp2-12",
        "auto-decimals-apostrophe-dot-dp0-12",
        "auto-decimals-comma-dot-in-dp2-12",
        "auto-decimals-comma-dot-in-dp0-12"
    ]

    @Test func fixtureCoversEveryNumberFormatAndScale() throws {
        let cases = try Self.cases.get()
        #expect(cases.count == 783)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(Set(cases.map(\.input.numberFormat)).count == 5)
        #expect(Set(cases.map(\.input.decimalPlaces)) == [0, 2])
        #expect(Set(cases.map(\.mode)) == ["fromEdit", "forEdit", "autoDecimals"])
        let ids = Set(cases.map(\.id))
        #expect(Self.hideFractionEditCaseIDs.isSubset(of: ids))
        #expect(Self.beyondLimitCaseIDs.isSubset(of: ids))
    }

    @Test func typedAmountsMatchActualFromEdit() throws {
        var failures: [String] = []
        var replayed = 0
        for testCase in try Self.cases.get() {
            guard case .fromEdit(let outcome) = testCase.expected, let text = testCase.input.text else { continue }
            replayed += 1
            let result = BudgetMoneyInputFormat.minorUnits(text, currency: Self.currency(testCase.input))
            let problem = Self.mismatch(result, expected: outcome)
            let label = "\(testCase.id) \(text.debugDescription): \(problem ?? "")"
            if Self.beyondLimitCaseIDs.contains(testCase.id) {
                withKnownIssue("OP-94: an amount beyond the maximum, or Infinity, is out of range where Actual returns it") {
                    #expect(problem == nil, Comment(rawValue: label))
                }
            } else if problem != nil {
                failures.append(label)
            }
        }
        #expect(replayed == 570)
        #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(40).joined(separator: "\n"))")
    }

    /// Actual's own edit text reads back to the amount it was made from, and the text Actualist
    /// writes is Actual's text.
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
            let label = "\(testCase.id) writes \(written.debugDescription), Actual \(text.debugDescription)"
            if Self.hideFractionEditCaseIDs.contains(testCase.id) {
                withKnownIssue("OP-93: with hide-fraction on, Actual's edit text drops the cents; Actualist keeps them") {
                    #expect(written == text, Comment(rawValue: label))
                }
            } else if written != text {
                failures.append(label)
            }
        }
        #expect(replayed == 83)
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
            var problems = [Self.mismatch(result, expected: amount)].compactMap { $0 }
            if shown != editText { problems.append("shows \(shown.debugDescription), Actual \(editText.debugDescription)") }
            let label = "\(testCase.id) \(typed.debugDescription): \(problems.joined(separator: "; "))"
            if Self.beyondLimitCaseIDs.contains(testCase.id) {
                withKnownIssue("OP-94: an amount beyond the maximum is out of range, and its text keeps every digit, where Actual rounds through a Double") {
                    #expect(problems.isEmpty, Comment(rawValue: label))
                }
            } else if !problems.isEmpty {
                failures.append(label)
            }
        }
        #expect(replayed == 130)
        #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(40).joined(separator: "\n"))")
    }
}
