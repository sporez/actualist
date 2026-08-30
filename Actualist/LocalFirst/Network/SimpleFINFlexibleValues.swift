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

/// UNIX seconds arriving as an integer, decimal, or numeric string.
struct FlexibleUnixSeconds: Decodable, Sendable {
    let seconds: Int64?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            seconds = value
        } else if let value = try? container.decode(Double.self) {
            seconds = Int64(value)
        } else if let text = try? container.decode(String.self),
                  let value = Double(text) {
            seconds = Int64(value)
        } else {
            seconds = nil
        }
    }
}
