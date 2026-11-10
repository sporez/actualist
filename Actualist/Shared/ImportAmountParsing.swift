import Foundation

/// Ports of Actual's import amount reading (pinned v26.11.0):
/// `looselyParseAmount` and `amountToInteger` from loot-core `shared/util.ts`,
/// and the single-column case of the import modal's `parseAmountFields`.
/// Values stay `Double` where Actual uses JS numbers, so every rounding step
/// matches. The `file-import` oracle replays each function.
enum ImportAmountParsing {
    /// `MAX_SAFE_NUMBER` (`2 ** 51 - 1`); `MIN_SAFE_NUMBER` is its negation.
    static let maxSafeNumber: Double = 2_251_799_813_685_247

    /// `looselyParseAmount`: reads an amount whatever its currency symbol,
    /// thousands separator or decimal mark. `nil` is JS `null`.
    static func looselyParseAmount(_ input: String) -> Double? {
        var amount = Array(JavaScriptText.trim(input).unicodeScalars)
        if amount.first == "(", amount.last == ")" {
            amount.removeAll { $0 == "\u{2212}" }
            if let open = amount.firstIndex(of: "(") { amount[open] = "-" }
            if let close = amount.firstIndex(of: ")") { amount.remove(at: close) }
        } else {
            amount = amount.map { $0 == "\u{2212}" ? "-" : $0 }
        }
        guard let marker = decimalMarkerIndex(amount) else {
            return safeNumber(JavaScriptText.parseFloat(numericText: extractNumbers(amount[...])))
        }
        let left = extractNumbers(amount[..<marker])
        let right = extractNumbers(amount[(marker + 1)...])
        return safeNumber(JavaScriptText.parseFloat(numericText: left + ["."] + right))
    }

    /// `amountToInteger`: `Math.round(amount * 10 ** decimalPlaces)`.
    static func amountToInteger(_ amount: Double, decimalPlaces: Int = 2) -> Double {
        JavaScriptText.round(amount * pow(10, Double(decimalPlaces)))
    }

    /// The amount column read with the modal's default options
    /// (`parseAmountFields(trans, false, false, '', false, '')`, then
    /// `amountToInteger`): a missing or unreadable cell is 0.
    static func singleColumnMinorUnits(_ text: String?) -> Int {
        let parsed = text.flatMap(looselyParseAmount) ?? 0
        // Within ±2^51 after `safeNumber`, so the conversion is exact.
        return Int(amountToInteger(parsed))
    }

    /// The match of `/[.,](\d{4,9}|\d{1,2})[^\d.,]*$/`. Its tail excludes
    /// separators, so only the last `.` or `,` can match, and only when the
    /// digit run after it is 1–2 or 4–9 long and nothing after that run is a
    /// digit.
    private static func decimalMarkerIndex(_ amount: [Unicode.Scalar]) -> Int? {
        guard let marker = amount.lastIndex(where: { $0 == "." || $0 == "," }) else { return nil }
        var end = marker + 1
        while end < amount.count, JavaScriptText.isDigit(amount[end]) {
            end += 1
        }
        let run = end - marker - 1
        guard (1...2).contains(run) || (4...9).contains(run),
              !amount[end...].contains(where: JavaScriptText.isDigit) else {
            return nil
        }
        return marker
    }

    /// `v.replace(/[^0-9-]/g, '')`.
    private static func extractNumbers(_ text: ArraySlice<Unicode.Scalar>) -> [Unicode.Scalar] {
        text.filter { JavaScriptText.isDigit($0) || $0 == "-" }
    }

    private static func safeNumber(_ value: Double) -> Double? {
        guard !value.isNaN else { return nil }
        let scaled = value * 100
        guard scaled <= maxSafeNumber, scaled >= -maxSafeNumber else { return nil }
        return value
    }
}
