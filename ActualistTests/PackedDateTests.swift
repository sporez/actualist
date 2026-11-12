import Foundation
import Testing
@testable import Actualist

/// `PackedDate` replaced several hand-written copies. The verbatim old bodies
/// are the oracle over boundary inputs, so each caller keeps its output and
/// failure value.
struct PackedDateTests {
    private static let packedValues: [Int] = [
        20_261_231, 20_260_101, 20_260_231, 20_261_332, 0, 1, -1, -5, -20_261_231, 2_026_123, 202_612_310,
        99_999_999, 100_000_000, 12_345_678, 10_101, 101, 99_991_231, 12_345_678_901,
    ]

    private static func oldPaddedISO(_ int: Int) -> String {
        let text = String(format: "%08d", int)
        return "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))"
    }

    private static func oldBatchMonthID(_ dateValue: Int?) -> String? {
        guard let dateValue, dateValue > 0 else { return nil }
        let date = String(format: "%08d", dateValue)
        guard date.count == 8 else { return nil }
        return String(date.prefix(4)) + "-" + String(date.dropFirst(4).prefix(2))
    }

    private static func oldPresentationDate(_ packed: Int) -> String? {
        let compact = String(format: "%08d", packed)
        guard compact.count == 8 else { return nil }
        return "\(compact.prefix(4))-\(compact.dropFirst(4).prefix(2))-\(compact.suffix(2))"
    }

    private static func oldPlannerDateID(for packedDate: Int) -> String? {
        guard packedDate > 0 else { return nil }
        let year = packedDate / 10_000
        let month = (packedDate / 100) % 100
        let day = packedDate % 100
        guard (1...9_999).contains(year) else { return nil }
        let dateID = String(format: "%04d-%02d-%02d", year, month, day)
        guard ActualDateOnly.date(from: dateID, timeZone: .gmt) != nil else { return nil }
        return dateID
    }

    private static func oldSnapshotPacked(_ raw: String) -> Int? {
        let digits = raw.filter(\.isNumber)
        return digits.count == 8 ? Int(digits) : nil
    }

    @Test func paddedISOMatchesTheRulesCopyForEveryValue() {
        for value in Self.packedValues {
            #expect(PackedDate.paddedISO(value) == Self.oldPaddedISO(value), "\(value)")
        }
        #expect(PackedDate.paddedISO(2_026_123) == "0202-61-23")
        #expect(PackedDate.paddedISO(202_612_310) == "2026-12-10")
    }

    @Test func eightCharacterVariantsMatchTheBatchAndPresentationCopies() {
        for value in Self.packedValues {
            #expect(PackedDate.monthID(ofDate: value) == Self.oldBatchMonthID(value), "\(value)")
            #expect(PackedDate.paddedISOIfEightCharacters(value) == Self.oldPresentationDate(value), "\(value)")
        }
        #expect(PackedDate.monthID(ofDate: nil) == nil)
        #expect(PackedDate.monthID(ofDate: 0) == nil)
        #expect(PackedDate.monthID(ofDate: -5) == nil)
        #expect(PackedDate.monthID(ofDate: 20_261_231) == "2026-12")
        #expect(PackedDate.monthID(ofDate: 202_612_310) == nil)
        #expect(PackedDate.paddedText(20_261_231) == "20261231")
        #expect(PackedDate.paddedText(-5) == "-0000005")
    }

    @Test func validatedISOMatchesThePlannerCopyAndYearMonthValidation() {
        for value in Self.packedValues {
            #expect(PackedDate.validatedISO(value) == Self.oldPlannerDateID(for: value), "\(value)")
            #expect(YearMonth(validatingPackedDate: value)?.rawValue == Self.oldPlannerDateID(for: value).map { String($0.prefix(7)) }, "\(value)")
        }
        #expect(PackedDate.validatedISO(20_260_229) == nil)
        #expect(PackedDate.validatedISO(20_280_229) == "2028-02-29")
    }

    @Test func eightDigitTextMatchesTheSnapshotCopy() {
        for raw in ["20261231", "2026-12-31", "2026/12/31", "202612", "202612310", "", "abcdefgh", "١٢٣٤٥٦٧٨", " 2026-12-31 "] {
            #expect(PackedDate.packed(fromEightDigitText: raw) == Self.oldSnapshotPacked(raw), "\(raw)")
        }
        #expect(PackedDate.packed(fromEightDigitText: "2026-12-31") == 20_261_231)
    }

    @Test func compactStripsEveryDash() {
        #expect(PackedDate.compact("2026-12-31") == "20261231")
        #expect(PackedDate.compact("2026-1-5") == "202615")
        #expect(PackedDate.compact("-") == "")
        #expect(PackedDate.compact("20261231") == "20261231")
        #expect(PackedDate.compact("2026-12-31T00:00") == "20261231T00:00")
    }

    @Test func isoFromPartsDoesNotValidate() {
        #expect(PackedDate.iso(year: 2026, month: 12, day: 31) == "2026-12-31")
        #expect(PackedDate.iso(year: 0, month: 0, day: 0) == "0000-00-00")
        #expect(PackedDate.iso(year: 2026, month: 13, day: 40) == "2026-13-40")
        #expect(PackedDate.iso(year: 1970, month: 1, day: 1) == "1970-01-01")
    }
}
