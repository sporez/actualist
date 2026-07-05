import Foundation
import SwiftProtobuf

struct ActualSync_Message: SwiftProtobuf.Message, Equatable, Sendable {
    static let protoMessageName = "Message"

    var dataset = ""
    var row = ""
    var column = ""
    var value = ""
    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1:
                try decoder.decodeSingularStringField(value: &dataset)
            case 2:
                try decoder.decodeSingularStringField(value: &row)
            case 3:
                try decoder.decodeSingularStringField(value: &column)
            case 4:
                try decoder.decodeSingularStringField(value: &value)
            default:
                break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !dataset.isEmpty {
            try visitor.visitSingularStringField(value: dataset, fieldNumber: 1)
        }
        if !row.isEmpty {
            try visitor.visitSingularStringField(value: row, fieldNumber: 2)
        }
        if !column.isEmpty {
            try visitor.visitSingularStringField(value: column, fieldNumber: 3)
        }
        if !value.isEmpty {
            try visitor.visitSingularStringField(value: value, fieldNumber: 4)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ActualSync_Message, rhs: ActualSync_Message) -> Bool {
        lhs.dataset == rhs.dataset
            && lhs.row == rhs.row
            && lhs.column == rhs.column
            && lhs.value == rhs.value
            && lhs.unknownFields == rhs.unknownFields
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? ActualSync_Message else {
            return false
        }
        return self == other
    }
}

struct ActualSync_MessageEnvelope: SwiftProtobuf.Message, Equatable, Sendable {
    static let protoMessageName = "MessageEnvelope"

    var timestamp = ""
    var isEncrypted = false
    var content = Data()
    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1:
                try decoder.decodeSingularStringField(value: &timestamp)
            case 2:
                try decoder.decodeSingularBoolField(value: &isEncrypted)
            case 3:
                try decoder.decodeSingularBytesField(value: &content)
            default:
                break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !timestamp.isEmpty {
            try visitor.visitSingularStringField(value: timestamp, fieldNumber: 1)
        }
        if isEncrypted {
            try visitor.visitSingularBoolField(value: isEncrypted, fieldNumber: 2)
        }
        if !content.isEmpty {
            try visitor.visitSingularBytesField(value: content, fieldNumber: 3)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ActualSync_MessageEnvelope, rhs: ActualSync_MessageEnvelope) -> Bool {
        lhs.timestamp == rhs.timestamp
            && lhs.isEncrypted == rhs.isEncrypted
            && lhs.content == rhs.content
            && lhs.unknownFields == rhs.unknownFields
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? ActualSync_MessageEnvelope else {
            return false
        }
        return self == other
    }
}

struct ActualSync_EncryptedData: SwiftProtobuf.Message, Equatable, Sendable {
    static let protoMessageName = "EncryptedData"

    var data = Data()
    var iv = Data()
    var authTag = Data()
    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1:
                try decoder.decodeSingularBytesField(value: &iv)
            case 2:
                try decoder.decodeSingularBytesField(value: &authTag)
            case 3:
                try decoder.decodeSingularBytesField(value: &data)
            default:
                break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !iv.isEmpty {
            try visitor.visitSingularBytesField(value: iv, fieldNumber: 1)
        }
        if !authTag.isEmpty {
            try visitor.visitSingularBytesField(value: authTag, fieldNumber: 2)
        }
        if !data.isEmpty {
            try visitor.visitSingularBytesField(value: data, fieldNumber: 3)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ActualSync_EncryptedData, rhs: ActualSync_EncryptedData) -> Bool {
        lhs.data == rhs.data
            && lhs.iv == rhs.iv
            && lhs.authTag == rhs.authTag
            && lhs.unknownFields == rhs.unknownFields
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? ActualSync_EncryptedData else {
            return false
        }
        return self == other
    }
}

struct ActualSync_SyncRequest: SwiftProtobuf.Message, Equatable, Sendable {
    static let protoMessageName = "SyncRequest"

    var messages: [ActualSync_MessageEnvelope] = []
    var fileID = ""
    var groupID = ""
    var keyID = ""
    var since = ""
    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1:
                try decoder.decodeRepeatedMessageField(value: &messages)
            case 2:
                try decoder.decodeSingularStringField(value: &fileID)
            case 3:
                try decoder.decodeSingularStringField(value: &groupID)
            case 5:
                try decoder.decodeSingularStringField(value: &keyID)
            case 6:
                try decoder.decodeSingularStringField(value: &since)
            default:
                break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !messages.isEmpty {
            try visitor.visitRepeatedMessageField(value: messages, fieldNumber: 1)
        }
        if !fileID.isEmpty {
            try visitor.visitSingularStringField(value: fileID, fieldNumber: 2)
        }
        if !groupID.isEmpty {
            try visitor.visitSingularStringField(value: groupID, fieldNumber: 3)
        }
        if !keyID.isEmpty {
            try visitor.visitSingularStringField(value: keyID, fieldNumber: 5)
        }
        if !since.isEmpty {
            try visitor.visitSingularStringField(value: since, fieldNumber: 6)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ActualSync_SyncRequest, rhs: ActualSync_SyncRequest) -> Bool {
        lhs.messages == rhs.messages
            && lhs.fileID == rhs.fileID
            && lhs.groupID == rhs.groupID
            && lhs.keyID == rhs.keyID
            && lhs.since == rhs.since
            && lhs.unknownFields == rhs.unknownFields
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? ActualSync_SyncRequest else {
            return false
        }
        return self == other
    }
}

struct ActualSync_SyncResponse: SwiftProtobuf.Message, Equatable, Sendable {
    static let protoMessageName = "SyncResponse"

    var messages: [ActualSync_MessageEnvelope] = []
    var merkle = ""
    var unknownFields = SwiftProtobuf.UnknownStorage()

    init() {}

    mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1:
                try decoder.decodeRepeatedMessageField(value: &messages)
            case 2:
                try decoder.decodeSingularStringField(value: &merkle)
            default:
                break
            }
        }
    }

    func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
        if !messages.isEmpty {
            try visitor.visitRepeatedMessageField(value: messages, fieldNumber: 1)
        }
        if !merkle.isEmpty {
            try visitor.visitSingularStringField(value: merkle, fieldNumber: 2)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    static func == (lhs: ActualSync_SyncResponse, rhs: ActualSync_SyncResponse) -> Bool {
        lhs.messages == rhs.messages
            && lhs.merkle == rhs.merkle
            && lhs.unknownFields == rhs.unknownFields
    }

    func isEqualTo(message: any SwiftProtobuf.Message) -> Bool {
        guard let other = message as? ActualSync_SyncResponse else {
            return false
        }
        return self == other
    }
}
