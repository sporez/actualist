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
            return safeNumber(JavaScriptText.parseFloat(extractNumbers(amount[...])))
        }
        let left = extractNumbers(amount[..<marker])
        let right = extractNumbers(amount[(marker + 1)...])
        return safeNumber(JavaScriptText.parseFloat(left + ["."] + right))
    }

    /// `amountToInteger`: `Math.round(amount * 10 ** decimalPlaces)`.
    static func amountToInteger(_ amount: Double, decimalPlaces: Int = 2) -> Double {
        JavaScriptText.round(amount * pow(10, Double(decimalPlaces)))
    }

    /// The amount modes `parseAmountFields` takes after the row.
    struct AmountModes: Equatable, Sendable {
        var splitMode = false
        var inOutMode = false
        var outValue = ""
        var flipAmount = false
        /// The modal's multiplier text (`^\d{1,}(\.\d{0,4})?$` or empty).
        var multiplier = ""
    }

    /// `parseAmountFields(trans, splitMode, inOutMode, outValue, flipAmount,
    /// multiplierAmount)`. `outflow` and `inflow` are `nil` (JS `null`)
    /// unless split mode is on. A missing or unreadable cell is 0.
    static func parseAmountFields(
        _ row: MappedImportRow,
        modes: AmountModes
    ) -> (amount: Double, outflow: Double?, inflow: Double?) {
        func truthy(_ value: Double) -> Bool { value != 0 && !value.isNaN }
        func or(_ value: Double?, _ fallback: Double) -> Double { value.map { truthy($0) ? $0 : fallback } ?? fallback }
        // `parseAmount(amount, mapper)`.
        func parse(_ text: String?, _ mapper: (Double) -> Double) -> Double? {
            text.flatMap(looselyParseAmount).map(mapper)
        }
        let parsedMultiplier = JavaScriptText.parseFloat(Array(modes.multiplier.unicodeScalars))
        let multiplier = truthy(parsedMultiplier) ? parsedMultiplier : 1.0
        var outflow = 0.0
        var inflow = 0.0
        if modes.splitMode && !modes.inOutMode {
            outflow = or(parse(row.outflow) { -abs($0) }, 0)
            inflow = truthy(outflow) ? 0 : or(parse(row.inflow) { abs($0) }, 0)
        } else {
            let amount = or(parse(row.amount) { $0 }, 0)
            if amount >= 0 { inflow = amount } else { outflow = amount }
        }
        if modes.inOutMode {
            let transactionValue = truthy(outflow) ? outflow : inflow
            if let inOut = row.inOut, JavaScriptText.identical(inOut, modes.outValue) {
                outflow = -abs(transactionValue)
                inflow = 0
            } else {
                inflow = abs(transactionValue)
                outflow = 0
            }
        }
        if modes.flipAmount {
            let oldInflow = inflow
            inflow = abs(outflow)
            outflow = -abs(oldInflow)
        }
        inflow *= multiplier
        outflow *= multiplier
        let amount = truthy(outflow) ? outflow : inflow
        return modes.splitMode ? (amount, outflow, inflow) : (amount, nil, nil)
    }

    /// The row's amount as `onImport` stores it: `amountToInteger` of
    /// `parseAmountFields(...).amount`.
    static func minorUnits(_ row: MappedImportRow, modes: AmountModes) -> Int {
        // Within ±2^51 times a multiplier of at most 10^n digits; the
        // conversion saturates rather than trapping for absurd multipliers.
        let scaled = amountToInteger(parseAmountFields(row, modes: modes).amount)
        guard scaled.isFinite else { return 0 }
        return Int(exactly: scaled) ?? (scaled < 0 ? Int.min : Int.max)
    }

    /// The amount column read with the modal's default options.
    static func singleColumnMinorUnits(_ text: String?) -> Int {
        minorUnits(MappedImportRow(amount: text), modes: AmountModes())
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
