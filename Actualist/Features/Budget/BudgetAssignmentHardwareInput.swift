import Foundation

enum BudgetAssignmentHardwareAction: Equatable {
    case digit(Int)
    case decimalPoint
    case addition
    case subtraction
    case commit
    case cancel
    case delete
    case next
    case previous
}

enum BudgetAssignmentHardwareInput {
    static func action(for input: String) -> BudgetAssignmentHardwareAction? {
        switch input {
        case "=", "\r", "\n": return .commit
        case "\u{1b}": return .cancel
        case "\u{8}", "\u{7f}": return .delete
        case "\t": return .next
        case "\u{19}": return .previous // Shift-Tab
        case ".": return .decimalPoint
        case "+": return .addition
        case "-": return .subtraction
        case let value where value.utf8.count == 1 && value.utf8.first.map({ (48...57).contains($0) }) == true:
            return .digit(Int(value)!)
        default: return nil
        }
    }

    /// Converts the human-entered operand to Actual's integer minor units.
    static func minorDigits(for text: String, currency: BudgetCurrency) -> String? {
        guard !text.isEmpty, currency.decimalPlaces >= 0 else { return nil }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2,
              let whole = pieces.first,
              !whole.isEmpty,
              whole.allSatisfy({ $0.isASCII && $0.isNumber }),
              whole != "-" else { return nil }
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
              fraction.count <= currency.decimalPlaces else { return nil }
        let scaled = String(whole) + fraction + String(repeating: "0", count: currency.decimalPlaces - fraction.count)
        let normalized = scaled.drop(while: { $0 == "0" })
        let digits = normalized.isEmpty ? "0" : String(normalized)
        guard digits.count <= BudgetAssignmentWorkflow.maxInputDigits,
              Int(digits) != nil else { return nil }
        return digits
    }

}
