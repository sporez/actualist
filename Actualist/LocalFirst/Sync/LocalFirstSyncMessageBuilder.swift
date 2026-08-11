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
    private static let nodeIDLength = 16
    private static let wallTimeFormatterLock = NSLock()
    private static let wallTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    let nodeID: String
    private(set) var lastTimestamp: String

    init(
        nodeID: String,
        lastTimestamp: String = "1970-01-01T00:00:00.000Z-0000-0000000000000000"
    ) {
        self.nodeID = Self.normalizedNodeID(nodeID)
        self.lastTimestamp = lastTimestamp
    }

    static func makeClientID(uuid: UUID = UUID()) -> String {
        normalizedNodeID(uuid.uuidString)
    }

    static func normalizedNodeID(_ nodeID: String) -> String {
        let compact = nodeID
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard compact.count > nodeIDLength else {
            return compact
        }
        return String(compact.suffix(nodeIDLength))
    }

    mutating func next(now: Date = Date()) throws -> String {
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
        guard counter <= 0xffff else {
            throw LocalFirstError.hybridLogicalClockOverflow
        }

        let timestamp = "\(nextWallTime)-\(String(format: "%04x", counter))-\(nodeID)"
        lastTimestamp = timestamp
        return timestamp
    }

    mutating func observe(_ timestamp: String) {
        guard let observed = Self.parse(timestamp) else {
            return
        }
        guard let current = Self.parse(lastTimestamp) else {
            lastTimestamp = timestamp
            return
        }
        if observed.wallTime > current.wallTime
            || (observed.wallTime == current.wallTime && observed.counter > current.counter) {
            lastTimestamp = timestamp
        }
    }

    private static func wallTimeString(for date: Date) -> String {
        wallTimeFormatterLock.lock()
        defer { wallTimeFormatterLock.unlock() }
        return wallTimeFormatter.string(from: date)
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
    private var sequence = 0

    init() {}

    mutating func makeMessage(
        dataset: String,
        row: String,
        column: String,
        value: LocalFirstSyncValue,
        now _: Date = Date()
    ) throws -> ActualSyncDecodedMessage {
        defer { sequence += 1 }
        return ActualSyncDecodedMessage(
            // The database actor assigns the HLC while committing the mutation.
            timestamp: String(format: "actualist-pending-%08x", sequence),
            dataset: dataset,
            row: row,
            column: column,
            serializedValue: value.serialized
        )
    }

    static func envelope(
        for message: ActualSyncDecodedMessage,
        encryptionContext: ActualBudgetEncryptionContext? = nil
    ) throws -> ActualSync_MessageEnvelope {
        var syncMessage = ActualSync_Message()
        syncMessage.dataset = message.dataset
        syncMessage.row = message.row
        syncMessage.column = message.column
        syncMessage.value = message.serializedValue

        var envelope = ActualSync_MessageEnvelope()
        envelope.timestamp = message.timestamp
        let messageData = try syncMessage.serializedData()
        if let encryptionContext {
            let encrypted = try ActualBudgetCrypto.encrypt(messageData, context: encryptionContext)
            var encryptedData = ActualSync_EncryptedData()
            encryptedData.data = encrypted.data
            encryptedData.iv = encrypted.iv
            encryptedData.authTag = encrypted.authTag
            envelope.isEncrypted = true
            envelope.content = try encryptedData.serializedData()
        } else {
            envelope.isEncrypted = false
            envelope.content = messageData
        }
        return envelope
    }

    static func envelopes(
        for messages: [ActualSyncDecodedMessage],
        encryptionContext: ActualBudgetEncryptionContext? = nil
    ) throws -> [ActualSync_MessageEnvelope] {
        try messages.map { try envelope(for: $0, encryptionContext: encryptionContext) }
    }
}
