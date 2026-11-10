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

    /// `parseFloat` on a string made only of ASCII digits, `-` and at most one
    /// `.` (what Actual's amount parser hands it): the longest prefix that is
    /// `-?digits(.digits)?` or `-?.digits`, else NaN.
    static func parseFloat(numericText text: [Unicode.Scalar]) -> Double {
        var index = 0
        var negative = false
        if index < text.count, text[index] == "-" {
            negative = true
            index += 1
        }
        var whole: [Unicode.Scalar] = []
        while index < text.count, isDigit(text[index]) {
            whole.append(text[index])
            index += 1
        }
        var fraction: [Unicode.Scalar] = []
        if index < text.count, text[index] == "." {
            var cursor = index + 1
            while cursor < text.count, isDigit(text[cursor]) {
                fraction.append(text[cursor])
                cursor += 1
            }
        }
        guard !whole.isEmpty || !fraction.isEmpty else { return .nan }
        let literal = (whole.isEmpty ? "0" : string(whole)) + (fraction.isEmpty ? "" : "." + string(fraction))
        // Swift's decimal parsing is correctly rounded, as JS's is, and
        // overflows to infinity rather than failing.
        let magnitude = Double(literal) ?? .infinity
        return negative ? -magnitude : magnitude
    }
}
