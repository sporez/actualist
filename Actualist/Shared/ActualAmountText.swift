import Foundation

/// Actual's reading of a typed amount: `fromEdit` in the web app's `useFormat`,
/// with `evalArithmetic` (loot-core `shared/arithmetic.ts`) and `currencyToAmount`
/// (`shared/util.ts`). The ports keep JavaScript semantics on purpose: UTF-16
/// positions, `\s` and `trim()` whitespace, `parseFloat` prefixes and
/// `Math.pow`, so the oracle fixture replays exactly. Money rounding to minor
/// units lives in `BudgetMoneyInputFormat`.
enum ActualAmountText {
    /// The amount in display units, or nil where Actual's `fromEdit` returns its default (null).
    static func fromEdit(_ text: String, numberFormat: ActualNumberFormat) -> Double? {
        let trimmed = trimmedUnits(Array(text.utf16))
        guard !trimmed.isEmpty else { return nil }
        let normalized = strippingLettersAndDirectionMarks(trimmed)
        if let value = evalArithmetic(normalized, numberFormat: numberFormat) {
            return value
        }
        guard let value = currencyToAmount(normalized, numberFormat: numberFormat), !value.isNaN else {
            return nil
        }
        return value
    }

    /// The last `.` or `,` is the decimal point, unless it is this format's thousands
    /// separator with three or more characters after it. Every other non-digit is dropped.
    static func currencyToAmount(_ units: [UInt16], numberFormat: ActualNumberFormat) -> Double? {
        let text = units.map { $0 == 0x2212 ? UInt16(ascii: "-") : $0 }
        let lastSeparator = text.lastIndex { $0 == UInt16(ascii: ".") || $0 == UInt16(ascii: ",") }
        var integer: [UInt16]
        var fraction: [UInt16]?
        if let index = lastSeparator,
           !(isThousandsSeparator(text[index], numberFormat) && index + 4 <= text.count) {
            integer = Array(text[..<index])
            fraction = Array(text[(index + 1)...])
        } else {
            integer = text
            fraction = nil
        }
        integer.removeAll { !(isDigit($0) || $0 == UInt16(ascii: "-")) }
        // Actual builds `integer + "." + fraction` and calls parseFloat; a missing
        // fraction is the text "null", which parseFloat stops at.
        return parseFloatPrefix(integer + [UInt16(ascii: ".")] + (fraction ?? Array("null".utf16)))
    }

    /// `+ - * / ^` and parentheses over numbers. nil for anything Actual cannot
    /// evaluate, including a NaN result.
    static func evalArithmetic(_ units: [UInt16], numberFormat: ActualNumberFormat) -> Double? {
        guard !units.isEmpty else { return nil }
        var parser = ArithmeticParser(
            units: units.filter { !isJSWhitespace($0) },
            numberFormat: numberFormat
        )
        guard let result = try? parser.parseAdditive(), !result.isNaN else { return nil }
        return result
    }

    /// `Math.round`: halves go toward positive infinity, so -2.5 is -2.
    static func javaScriptRound(_ value: Double) -> Double {
        let floor = value.rounded(.down)
        return value - floor >= 0.5 ? floor + 1 : floor
    }

    /// Whether `trim()` would keep this unit; false for a blank-only field.
    static func isTrimmedAway(_ unit: UInt16) -> Bool { isJSWhitespace(unit) }

    // MARK: Parser

    /// Recursive descent with Actual's precedence. Input after the first complete
    /// expression is ignored, as in Actual. Depth is capped so pasted text cannot
    /// exhaust the stack; Actual's own limit is its JavaScript stack.
    private struct ArithmeticParser {
        struct Failure: Error {}
        static let maximumDepth = 256

        let units: [UInt16]
        let numberFormat: ActualNumberFormat
        var index = 0
        var depth = 0

        init(units: [UInt16], numberFormat: ActualNumberFormat) {
            self.units = units
            self.numberFormat = numberFormat
        }

        private var current: UInt16? { index < units.count ? units[index] : nil }

        private mutating func take(_ character: Character) -> Bool {
            guard current == character.utf16.first else { return false }
            index += 1
            return true
        }

        private mutating func parsePrimary() throws -> Double {
            let negative = take("-")
            var number: [UInt16] = []
            while let unit = current, ActualAmountText.isNumberCharacter(unit) {
                number.append(unit)
                index += 1
            }
            guard !number.isEmpty,
                  let value = ActualAmountText.currencyToAmount(number, numberFormat: numberFormat) else {
                throw Failure()
            }
            return negative ? -value : value
        }

        private mutating func parseParens() throws -> Double {
            guard take("(") else { return try parsePrimary() }
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maximumDepth else { throw Failure() }
            let value = try parseAdditive()
            guard take(")") else { throw Failure() }
            return value
        }

        private mutating func parseExponent() throws -> Double {
            let base = try parseParens()
            guard take("^") else { return base }
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maximumDepth else { throw Failure() }
            return ActualAmountText.javaScriptPow(base, try parseExponent())
        }

        private mutating func parseMultiplicative() throws -> Double {
            var value = try parseExponent()
            while let unit = current, unit == UInt16(ascii: "*") || unit == UInt16(ascii: "/") {
                index += 1
                let right = try parseExponent()
                value = unit == UInt16(ascii: "*") ? value * right : value / right
            }
            return value
        }

        mutating func parseAdditive() throws -> Double {
            var value = try parseMultiplicative()
            while let unit = current, unit == UInt16(ascii: "+") || unit == UInt16(ascii: "-") {
                index += 1
                let right = try parseMultiplicative()
                value = unit == UInt16(ascii: "+") ? value + right : value - right
            }
            return value
        }
    }

    // MARK: JavaScript semantics

    /// `Math.pow` differs from C `pow` where the base is 1 or -1 with an infinite exponent, and for a NaN exponent.
    fileprivate static func javaScriptPow(_ base: Double, _ exponent: Double) -> Double {
        if exponent.isNaN || (exponent.isInfinite && abs(base) == 1) { return .nan }
        return pow(base, exponent)
    }

    /// The characters `arithmetic.ts` accepts inside a number: digits, `,` `.` `'`
    /// U+2019, U+00A0, U+202F, space, and any currency symbol.
    fileprivate static func isNumberCharacter(_ unit: UInt16) -> Bool {
        if isDigit(unit) { return true }
        switch unit {
        case UInt16(ascii: ","), UInt16(ascii: "."), UInt16(ascii: "'"), 0x2019, 0x00A0, 0x202F, 0x20:
            return true
        default:
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return scalar.properties.generalCategory == .currencySymbol
        }
    }

    private static func isThousandsSeparator(_ unit: UInt16, _ format: ActualNumberFormat) -> Bool {
        format.thousandsSeparator.utf16.first == unit
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= UInt16(ascii: "0") && unit <= UInt16(ascii: "9")
    }

    /// JavaScript `\s` and `String.prototype.trim` whitespace.
    private static func isJSWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    private static func trimmedUnits(_ units: [UInt16]) -> [UInt16] {
        guard let first = units.firstIndex(where: { !isJSWhitespace($0) }),
              let last = units.lastIndex(where: { !isJSWhitespace($0) }) else {
            return []
        }
        return Array(units[first...last])
    }

    /// Removes the directional formatting characters and every letter (`\p{L}`).
    private static func strippingLettersAndDirectionMarks(_ units: [UInt16]) -> [UInt16] {
        var result: [UInt16] = []
        for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
            switch scalar.value {
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                continue
            default:
                break
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                continue
            default:
                result.append(contentsOf: String(scalar).utf16)
            }
        }
        return result
    }

    /// `parseFloat` for the text `currencyToAmount` builds: an optional minus, digits
    /// with an optional point, and nothing else is read. nil where JavaScript gives NaN.
    private static func parseFloatPrefix(_ units: [UInt16]) -> Double? {
        var position = 0
        var negative = false
        if position < units.count, units[position] == UInt16(ascii: "-") {
            negative = true
            position += 1
        }
        func digits() -> String {
            var text = ""
            while position < units.count, isDigit(units[position]) {
                text.unicodeScalars.append(Unicode.Scalar(units[position])!)
                position += 1
            }
            return text
        }
        let whole = digits()
        var fraction = ""
        if position < units.count, units[position] == UInt16(ascii: ".") {
            position += 1
            fraction = digits()
        }
        guard !whole.isEmpty || !fraction.isEmpty else { return nil }
        return Double("\(negative ? "-" : "")\(whole.isEmpty ? "0" : whole).\(fraction.isEmpty ? "0" : fraction)")
    }
}

private extension UInt16 {
    init(ascii character: Unicode.Scalar) {
        self = UInt16(character.value)
    }
}
