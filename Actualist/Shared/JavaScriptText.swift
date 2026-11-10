import Foundation

/// JavaScript string semantics that the ports of Actual's import code rely on.
/// Swift's own `trimmingCharacters(in: .whitespacesAndNewlines)`, `isNumber`
/// and `lowercased()` differ from JS at the edges, so ports use these instead.
/// Every pattern the ports match is ASCII, so working on Unicode scalars gives
/// the same result as JS's UTF-16 code units.
enum JavaScriptText {
    /// `String.prototype.trim`: ECMAScript WhiteSpace and LineTerminator.
    /// Unlike Swift's set it includes U+FEFF and excludes U+0085.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    static func trim(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let start = scalars.firstIndex(where: { !isWhitespace($0) }),
              let end = scalars.lastIndex(where: { !isWhitespace($0) }) else {
            return ""
        }
        return string(scalars[start...end])
    }

    /// Regex `\d` without the `u` flag: ASCII 0-9 only.
    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    /// Regex `\w` without the `u` flag: ASCII letters, digits and `_`.
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || isASCIILetter(scalar) || scalar == "_"
    }

    static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    /// ASCII-only lowercasing. It equals JS `toLowerCase()` for the purpose of
    /// finding an ASCII needle that contains no `i` or `k`: no other non-ASCII
    /// character lowercases to an ASCII letter.
    static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x41, scalar.value <= 0x5A,
              let lower = Unicode.Scalar(scalar.value + 0x20) else { return scalar }
        return lower
    }

    /// `name.toLowerCase().includes(needle)` for an ASCII needle without `i`
    /// or `k` (see `asciiLowercased`), compared scalar by scalar as JS does,
    /// with no canonical equivalence.
    static func lowercasedContains(_ text: String, asciiNeedle needle: String) -> Bool {
        let haystack = text.unicodeScalars.map(asciiLowercased)
        let pattern = Array(needle.unicodeScalars)
        guard !pattern.isEmpty else { return true }
        guard haystack.count >= pattern.count else { return false }
        for start in 0...(haystack.count - pattern.count)
        where haystack[start..<(start + pattern.count)].elementsEqual(pattern) {
            return true
        }
        return false
    }

    /// JS `===` on strings: same code units. Swift `==` also equates
    /// canonically equivalent text (`"é"` and `"e\u{301}"`), which JS does not.
    static func identical(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    /// A hashable key with JS `===` equality.
    static func exactKey(_ text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `Math.round`: the nearest integer, ties toward +∞, and -0 for any
    /// negative input that rounds to zero.
    static func round(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let floor = value.rounded(.down)
        // Exact: a double minus its floor is always representable.
        let result = value - floor >= 0.5 ? floor + 1 : floor
        return result == 0 && value.sign == .minus ? -0.0 : result
    }

    /// `parseInt(text, 10)`: leading whitespace, an optional sign, then the
    /// longest run of ASCII digits; `nil` (NaN) when there are none. Values
    /// beyond `Int` saturate, which no caller can tell apart.
    static func parseInt(_ text: String) -> Int? {
        var scalars = Substring(text).unicodeScalars.drop(while: isWhitespace)[...]
        var negative = false
        if let sign = scalars.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            scalars = scalars.dropFirst()
        }
        let digits = scalars.prefix(while: isDigit)
        guard !digits.isEmpty else { return nil }
        var value = 0
        for digit in digits {
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflowSum) = shifted.addingReportingOverflow(Int(digit.value - 0x30))
            guard !overflow, !overflowSum else { return negative ? Int.min : Int.max }
            value = sum
        }
        return negative ? -value : value
    }

    /// `String(value)` for a JS number: integers print without a fraction.
    /// Other values (which no import setting holds) use Swift's shortest form.
    static func numberToString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), abs(value) < 1e21 {
            return value == 0 ? "0" : String(format: "%.0f", value)
        }
        return String(value)
    }

    /// `parseFloat`: after leading whitespace, the longest prefix that is a
    /// decimal literal (`[+-]`, `Infinity`, digits, one `.`, an exponent),
    /// else NaN.
    static func parseFloat(_ text: [Unicode.Scalar]) -> Double {
        var index = text.firstIndex { !isWhitespace($0) } ?? text.count
        var negative = false
        if index < text.count, text[index] == "-" || text[index] == "+" {
            negative = text[index] == "-"
            index += 1
        }
        if text[index...].starts(with: "Infinity".unicodeScalars) {
            return negative ? -.infinity : .infinity
        }
        func digits() -> [Unicode.Scalar] {
            let run = text[index...].prefix(while: isDigit)
            index += run.count
            return Array(run)
        }
        let whole = digits()
        var fraction: [Unicode.Scalar] = []
        if index < text.count, text[index] == "." {
            index += 1
            fraction = digits()
        }
        guard !whole.isEmpty || !fraction.isEmpty else { return .nan }
        var exponent = ""
        if index < text.count, text[index] == "e" || text[index] == "E" {
            var cursor = index + 1
            var sign = ""
            if cursor < text.count, text[cursor] == "-" || text[cursor] == "+" {
                sign = text[cursor] == "-" ? "-" : ""
                cursor += 1
            }
            let run = text[cursor...].prefix(while: isDigit)
            if !run.isEmpty {
                exponent = "e" + sign + string(run)
            }
        }
        let literal = (whole.isEmpty ? "0" : string(whole)) + (fraction.isEmpty ? "" : "." + string(fraction)) + exponent
        // Swift's decimal parsing is correctly rounded, as JS's is, and
        // overflows to infinity.
        let isZero = (whole + fraction).allSatisfy { $0 == "0" }
        let magnitude = Double(literal) ?? (isZero ? 0 : (exponent.hasPrefix("e-") ? 0 : .infinity))
        return negative ? -magnitude : magnitude
    }
}
