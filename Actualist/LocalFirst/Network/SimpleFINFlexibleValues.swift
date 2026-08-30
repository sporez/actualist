import Foundation

/// Defensive decoders shared by the SimpleFIN transports (server routes and
/// the direct bridge). Bridge/server payloads ship numbers as strings,
/// numbers, or nulls depending on version; these never guess into data.

/// A value that may arrive as a JSON string or number; surfaced as text.
struct FlexibleString: Decodable, Sendable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            text = value
        } else if let value = try? container.decode(Double.self) {
            text = String(value)
        } else {
            text = nil
        }
    }
}

/// A boolean that may arrive as `true`, `1`, or `"true"`. `nil` when absent
/// or unreadable so callers can distinguish "did not say" from `false`.
struct SimpleFINFlexibleBool: Decodable, Sendable {
    let value: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let number = try? container.decode(Int.self) {
            value = number != 0
        } else if let text = try? container.decode(String.self) {
            value = ["1", "true", "yes"].contains(text.lowercased())
        } else {
            value = nil
        }
    }
}

/// A transaction date arriving as UNIX seconds (number/numeric string) or as
/// the sync-server's normalized `YYYY-MM-DD` day string.
struct FlexibleUnixSeconds: Decodable, Sendable {
    let seconds: Int64?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            seconds = value
        } else if let value = try? container.decode(Double.self) {
            seconds = Int64(value)
        } else if let text = try? container.decode(String.self) {
            if let value = Double(text) {
                seconds = Int64(value)
            } else {
                seconds = Self.unixSeconds(fromDay: text)
            }
        } else {
            seconds = nil
        }
    }

    private static func unixSeconds(fromDay day: String) -> Int64? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let dayOfMonth = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: dayOfMonth,
            hour: 12
        )
        guard let date = calendar.date(from: components) else {
            return nil
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == dayOfMonth else {
            return nil
        }
        return Int64(date.timeIntervalSince1970)
    }
}
