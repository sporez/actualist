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
    private static let nodeIDLength = 16

    let nodeID: String
    private(set) var lastTimestamp: String

    init(
        nodeID: String,
        lastTimestamp: String = SyncTimestamp.zeroString
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

    /// Mirrors upstream `Timestamp.send`: the clock never moves backward, and it
    /// refuses to mint a timestamp more than five minutes ahead of `now`.
    mutating func next(now: Date = Date()) throws -> String {
        let nowWallTime = SyncTimestamp.wallTimeString(for: now)
        let parsedLast = SyncTimestamp.parse(lastTimestamp)
        let nextWallTime: String
        let counter: Int

        if let parsedLast, parsedLast.wallTime >= nowWallTime {
            if parsedLast.exceedsDrift(now: now) {
                throw LocalFirstError.clockDrift
            }
            nextWallTime = parsedLast.wallTime
            counter = parsedLast.counter + 1
        } else {
            nextWallTime = nowWallTime
            counter = 0
        }
        guard counter <= 0xffff else {
            throw LocalFirstError.hybridLogicalClockOverflow
        }

        // Actual's reference Timestamp.toString uppercases the counter. Peers hash the
        // verbatim timestamp string into the merkle trie, so lowercase hex corrupts sync.
        let timestamp = "\(nextWallTime)-\(String(format: "%04X", counter))-\(nodeID)"
        lastTimestamp = timestamp
        return timestamp
    }

    /// Ignores anything that is not a strictly valid timestamp. Drift is judged
    /// by the batch validation before a remote message can be observed.
    mutating func observe(_ timestamp: String) {
        guard let observed = SyncTimestamp.parse(timestamp) else {
            return
        }
        guard let current = SyncTimestamp.parse(lastTimestamp) else {
            lastTimestamp = timestamp
            return
        }
        if observed.wallTime > current.wallTime
            || (observed.wallTime == current.wallTime && observed.counter > current.counter) {
            lastTimestamp = timestamp
        }
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
