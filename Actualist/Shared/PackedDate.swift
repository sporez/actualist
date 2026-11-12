import Foundation

/// Actual's packed calendar days (`YYYYMMDD` as an `Int`) and their text forms.
///
/// Each method keeps one copy's exact output and failure value, so a caller
/// picks the variant that matches what it always did: unvalidated formatting,
/// a `0`/`nil` failure, or full calendar validation.
enum PackedDate {
    /// The text with every `-` removed: an ISO day or month as digits.
    static func compact(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: "")
    }

    /// An ISO day as a packed `Int`, or `0` when the text is nil or not
    /// digits once dashes are removed. Nothing is range-checked.
    static func packed(fromISO date: String?) -> Int {
        Int(compact(date ?? "")) ?? 0
    }

    /// `YYYY-MM-DD` from the parts, with no range validation.
    static func iso(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// `YYYY-MM-DD` split arithmetically from a packed value, with no
    /// validation (`0` is "0000-00-00").
    static func iso(_ packed: Int) -> String {
        iso(year: packed / 10_000, month: (packed / 100) % 100, day: packed % 100)
    }

    /// The packed value zero-padded to eight digits (`%08d`).
    static func paddedText(_ packed: Int) -> String {
        String(format: "%08d", packed)
    }

    /// `YYYY-MM-DD` cut from the zero-padded eight-digit text by position. A
    /// value wider than eight digits keeps its extra digits in the day cut.
    static func paddedISO(_ packed: Int) -> String {
        let text = paddedText(packed)
        return "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))"
    }

    /// `paddedISO`, or nil unless the padded text is exactly eight characters
    /// (a value of nine digits or more, or a negative one of eight or more).
    static func paddedISOIfEightCharacters(_ packed: Int) -> String? {
        paddedText(packed).count == 8 ? paddedISO(packed) : nil
    }

    /// `YYYY-MM` for a positive packed day whose padded text is eight
    /// characters; nil otherwise.
    static func monthID(ofDate packed: Int?) -> String? {
        guard let packed, packed > 0 else { return nil }
        return paddedISOIfEightCharacters(packed).map { String($0.prefix(7)) }
    }

    /// A stored text date as a packed value: only when it holds exactly eight
    /// numeric characters (dashes and other symbols are ignored).
    static func packed(fromEightDigitText raw: String) -> Int? {
        let digits = raw.filter(\.isNumber)
        return digits.count == 8 ? Int(digits) : nil
    }

    /// `YYYY-MM-DD` only for a packed value that is a real Gregorian calendar
    /// day in years 1...9999; nil otherwise.
    static func validatedISO(_ packed: Int) -> String? {
        guard packed > 0 else { return nil }
        let year = packed / 10_000
        guard (1...9_999).contains(year) else { return nil }
        let dateID = iso(packed)
        guard ActualDateOnly.date(from: dateID, timeZone: .gmt) != nil else { return nil }
        return dateID
    }
}
