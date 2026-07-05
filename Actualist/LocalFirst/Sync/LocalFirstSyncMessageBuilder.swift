import Foundation
import SwiftProtobuf

enum LocalFirstSyncValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
    case bool(Bool)

    var serialized: String {
        switch self {
        case .null:
            return "0:"
        case .int(let value):
            return "N:\(value)"
        case .double(let value):
            return "N:\(value)"
        case .string(let value):
            return "S:\(value)"
        case .bool(let value):
            return "N:\(value ? 1 : 0)"
        }
    }
}

struct HybridLogicalClock: Equatable, Sendable {
    private static let timestampLength = 24

    let nodeID: String
    private(set) var lastTimestamp: String

    init(
        nodeID: String,
        lastTimestamp: String = "1970-01-01T00:00:00.000Z-0000-0000000000000000"
    ) {
        self.nodeID = nodeID
        self.lastTimestamp = lastTimestamp
    }

    mutating func next(now: Date = Date()) -> String {
        let nowWallTime = Self.wallTimeString(for: now)
        let parsedLast = Self.parse(lastTimestamp)
        let nextWallTime: String
        let counter: Int

        if let parsedLast, parsedLast.wallTime >= nowWallTime {
            nextWallTime = parsedLast.wallTime
            counter = parsedLast.counter + 1
        } else {
            nextWallTime = nowWallTime
            counter = 0
        }

        let timestamp = "\(nextWallTime)-\(String(format: "%04x", counter))-\(nodeID)"
        lastTimestamp = timestamp
        return timestamp
    }

    private static func wallTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static func parse(_ timestamp: String) -> (wallTime: String, counter: Int)? {
        guard timestamp.count >= timestampLength + 6 else {
            return nil
        }
        let wallEnd = timestamp.index(timestamp.startIndex, offsetBy: timestampLength)
        let wallTime = String(timestamp[..<wallEnd])
        let counterStart = timestamp.index(after: wallEnd)
        let counterEnd = timestamp.index(counterStart, offsetBy: 4, limitedBy: timestamp.endIndex) ?? timestamp.endIndex
        guard counterEnd <= timestamp.endIndex else {
            return nil
        }
        let counter = Int(timestamp[counterStart..<counterEnd], radix: 16) ?? 0
        return (wallTime, counter)
    }
}

struct LocalFirstSyncMessageBuilder: Sendable {
    var clock: HybridLogicalClock

    init(nodeID: String, latestTimestamp: String) {
        clock = HybridLogicalClock(nodeID: nodeID, lastTimestamp: latestTimestamp)
    }

    mutating func makeMessage(
        dataset: String,
        row: String,
        column: String,
        value: LocalFirstSyncValue,
        now: Date = Date()
    ) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: clock.next(now: now),
            dataset: dataset,
            row: row,
            column: column,
            serializedValue: value.serialized
        )
    }

    static func envelope(for message: ActualSyncDecodedMessage) throws -> ActualSync_MessageEnvelope {
        var syncMessage = ActualSync_Message()
        syncMessage.dataset = message.dataset
        syncMessage.row = message.row
        syncMessage.column = message.column
        syncMessage.value = message.serializedValue

        var envelope = ActualSync_MessageEnvelope()
        envelope.timestamp = message.timestamp
        envelope.isEncrypted = false
        envelope.content = try syncMessage.serializedData()
        return envelope
    }

    static func envelopes(for messages: [ActualSyncDecodedMessage]) throws -> [ActualSync_MessageEnvelope] {
        try messages.map(envelope(for:))
    }
}
