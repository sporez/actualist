import Testing
@testable import Actualist

struct BudgetAssignmentHardwareInputTests {
    @Test func mapsEditingKeys() {
        #expect(BudgetAssignmentHardwareInput.action(for: "7") == .digit(7))
        #expect(BudgetAssignmentHardwareInput.action(for: ".") == .decimalPoint)
        #expect(BudgetAssignmentHardwareInput.action(for: "+") == .addition)
        #expect(BudgetAssignmentHardwareInput.action(for: "-") == .subtraction)
        #expect(BudgetAssignmentHardwareInput.action(for: "=") == .commit)
        #expect(BudgetAssignmentHardwareInput.action(for: "\r") == .commit)
        #expect(BudgetAssignmentHardwareInput.action(for: "\u{1b}") == .cancel)
        #expect(BudgetAssignmentHardwareInput.action(for: "\u{7f}") == .delete)
        #expect(BudgetAssignmentHardwareInput.action(for: "\t") == .next)
        #expect(BudgetAssignmentHardwareInput.action(for: "\u{19}") == .previous)
    }

    @Test func rejectsMalformedOrImpreciseNumbers() {
        for value in ["", ".", "1.234", "1.2.3", "-1", "1e2", "1234567890"] {
            #expect(BudgetAssignmentHardwareInput.minorDigits(for: value, currency: .usd) == nil)
        }
        #expect(BudgetAssignmentHardwareInput.action(for: "12") == nil)
    }

    @Test func scalesSupportedCurrencyPrecisionsWithoutRounding() {
        #expect(BudgetAssignmentHardwareInput.minorDigits(for: "12.34", currency: .usd) == "1234")
        #expect(BudgetAssignmentHardwareInput.minorDigits(for: "12", currency: .jpy) == "12")
        #expect(BudgetAssignmentHardwareInput.minorDigits(for: "12.345", currency: BudgetCurrency(code: "KWD", decimalPlaces: 3, hideFraction: false)) == "12345")
        #expect(BudgetAssignmentHardwareInput.minorDigits(for: "12.3456", currency: BudgetCurrency(code: "KWD", decimalPlaces: 3, hideFraction: false)) == nil)
    }
}
