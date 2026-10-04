import Foundation
import Synchronization

/// A strictly parsed Actual hybrid-logical-clock timestamp:
/// `2026-09-08T00:00:00.000Z-00AF-0123456789abcdef`.
///
/// Mirrors upstream `Timestamp.parse` and `Timestamp.recv`
/// (`packages/crdt/src/crdt/timestamp.ts`): five dash-separated parts, a real
/// millisecond ISO time, a hex counter no greater than 0xFFFF and a node of at
/// most 16 characters. Anything else is rejected rather than trusted, so a
/// malformed or far-future remote value can never reach `since` or the local
/// clock.
struct SyncTimestamp: Equatable, Sendable {
    /// Upstream `config.maxDrift`: five minutes.
    static let maximumDriftMilliseconds: Int64 = 5 * 60 * 1_000
    static let zeroString = "1970-01-01T00:00:00.000Z-0000-0000000000000000"

    private static let wallTimeLength = 24
    private static let maximumNodeLength = 16

    let wallTime: String
    let milliseconds: Int64
    let counter: Int
    let node: String

    static func parse(_ string: String) -> SyncTimestamp? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[3].count == 4,
              parts[3].allSatisfy(\.isHexDigit),
              let counter = Int(parts[3], radix: 16),
              !parts[4].isEmpty,
              parts[4].count <= maximumNodeLength,
              parts[4].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        let wallTime = parts[0...2].joined(separator: "-")
        guard wallTime.count == wallTimeLength,
              let date = wallTimeDate(from: wallTime),
              wallTimeString(for: date) == wallTime else {
            return nil
        }
        let milliseconds = milliseconds(of: date)
        guard milliseconds >= 0 else { return nil }
        return SyncTimestamp(
            wallTime: wallTime,
            milliseconds: milliseconds,
            counter: counter,
            node: String(parts[4])
        )
    }

    static func milliseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func wallTimeString(for date: Date) -> String {
        wallTimeFormatter.withLock { $0.string(from: date) }
    }

    /// Lenient inverse of `wallTimeString(for:)`, also used for the outbox and
    /// action-log `created_at` text. `parse` adds the strict round-trip check.
    static func wallTimeDate(from string: String) -> Date? {
        wallTimeFormatter.withLock { $0.date(from: string) }
    }

    /// `true` when this timestamp is more than the allowed drift ahead of `now`.
    func exceedsDrift(now: Date) -> Bool {
        milliseconds - Self.milliseconds(of: now) > Self.maximumDriftMilliseconds
    }

    /// Validates a whole remote batch before anything is applied, like upstream
    /// `receiveMessages`, which calls `Timestamp.recv` for every message first.
    static func validateRemoteBatch(_ timestamps: some Sequence<String>, now: Date) throws {
        for string in timestamps {
            guard let parsed = parse(string) else {
                throw LocalFirstError.invalidSyncTimestamp
            }
            if parsed.exceedsDrift(now: now) {
                throw LocalFirstError.clockDrift
            }
        }
    }

    /// The `since` to send: the newest stored timestamp, but never further than
    /// the allowed drift ahead of `now`. Rows stored before validation existed
    /// may carry a future or malformed value that would otherwise freeze sync.
    static func clampedSince(storedMaximum: String?, now: Date) -> String {
        let ceiling = wallTimeString(for: now.addingTimeInterval(
            TimeInterval(maximumDriftMilliseconds) / 1_000
        )) + "-0000-0000000000000000"
        guard let storedMaximum, let parsed = parse(storedMaximum) else {
            return zeroString
        }
        return parsed.wallTime > String(ceiling.prefix(wallTimeLength)) ? ceiling : storedMaximum
    }

    private static let wallTimeFormatter = Mutex(makeWallTimeFormatter())

    private static func makeWallTimeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }
}
