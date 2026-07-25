import CryptoKit
import Foundation
import OSLog
import SwiftProtobuf

struct LocalFirstSyncConfiguration: Equatable, Sendable {
    let fileID: String
    let groupID: String?
    let nodeID: String
    let encryptionKeyID: String?
    let encryptionContext: ActualBudgetEncryptionContext?
}

struct PlaintextEnvelopeAuditEvent: Equatable, Sendable {
    let budgetIDHash: String
    let plaintextMessageCount: Int
    let totalMessageCount: Int
    let earliestTimestamp: String
    let latestTimestamp: String
    let hasEncryptionContext: Bool
}

struct LocalFirstSyncResult: Equatable, Sendable {
    let pushedMessageCount: Int
    let appliedRemoteMessageCount: Int
    let insertedTransactionIDsByAccount: [String: [String]]

    init(
        pushedMessageCount: Int,
        appliedRemoteMessageCount: Int,
        insertedTransactionIDsByAccount: [String: [String]] = [:]
    ) {
        self.pushedMessageCount = pushedMessageCount
        self.appliedRemoteMessageCount = appliedRemoteMessageCount
        self.insertedTransactionIDsByAccount = insertedTransactionIDsByAccount
    }
}

actor SyncClient {
    private static let securityLogger = Logger(
        subsystem: "com.sporez.actualist",
        category: "SyncSecurity"
    )

    private(set) var configuration: LocalFirstSyncConfiguration?
    private let resourceLimits: LocalFirstResourceLimits
    private let enforcesAuthenticatedEncryptedEnvelopes: Bool
    private let plaintextEnvelopeAuditRecorder: (@Sendable (PlaintextEnvelopeAuditEvent) -> Void)?

    init(
        resourceLimits: LocalFirstResourceLimits = .standard,
        enforcesAuthenticatedEncryptedEnvelopes: Bool = false,
        plaintextEnvelopeAuditRecorder: (@Sendable (PlaintextEnvelopeAuditEvent) -> Void)? = nil
    ) {
        self.resourceLimits = resourceLimits
        self.enforcesAuthenticatedEncryptedEnvelopes = enforcesAuthenticatedEncryptedEnvelopes
        self.plaintextEnvelopeAuditRecorder = plaintextEnvelopeAuditRecorder
    }

    func configure(_ configuration: LocalFirstSyncConfiguration) {
        self.configuration = configuration
    }

    func pullAndApply(
        database: BudgetDatabase,
        client: any ActualSyncTransport,
        token: String
    ) async throws -> BudgetDatabase.RemoteSyncApplyResult {
        guard let configuration else {
            return .empty
        }

        var request = ActualSync_SyncRequest()
        request.fileID = configuration.fileID
        request.groupID = configuration.groupID ?? ""
        request.keyID = configuration.encryptionKeyID ?? ""
        request.since = try await database.latestSyncTimestamp()

        let responseData = try await client.sync(data: try request.serializedData(), token: token)
        try validateResponseSize(responseData)
        let response = try ActualSync_SyncResponse(serializedBytes: responseData)
        let messages = try decodedMessages(from: response, configuration: configuration)
        return try await database.applyRemoteSyncMessagesTrackingInserts(messages)
    }

    func pushAndPull(
        database: BudgetDatabase,
        client: any ActualSyncTransport,
        token: String,
        messages: [ActualSyncDecodedMessage],
        since: String? = nil
    ) async throws -> LocalFirstSyncResult {
        guard let configuration else {
            throw LocalFirstError.budgetNotOpened
        }

        var request = ActualSync_SyncRequest()
        request.messages = try LocalFirstSyncMessageBuilder.envelopes(
            for: messages,
            encryptionContext: configuration.encryptionContext
        )
        request.fileID = configuration.fileID
        request.groupID = configuration.groupID ?? ""
        request.keyID = configuration.encryptionKeyID ?? ""
        if let since {
            request.since = since
        } else {
            request.since = try await database.latestSyncTimestamp()
        }

        let responseData = try await client.sync(data: try request.serializedData(), token: token)
        try validateResponseSize(responseData)
        let response = try ActualSync_SyncResponse(serializedBytes: responseData)
        var responseEnvelopes = response.messages
        let pushedEnvelopesByTimestamp = Dictionary(
            request.messages.map { ($0.timestamp, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        var confirmedTimestamps = Set(responseEnvelopes.compactMap { envelope in
            pushedEnvelopesByTimestamp[envelope.timestamp] == envelope ? envelope.timestamp : nil
        })

        // The official Actual server reads messages newer than `since` before inserting this
        // request's upload, so the first response normally does not echo what was just pushed.
        // Read once more from the same base timestamp and only acknowledge the durable outbox
        // after every uploaded timestamp is visible from the server.
        if confirmedTimestamps.count != pushedEnvelopesByTimestamp.count {
            var confirmationRequest = ActualSync_SyncRequest()
            confirmationRequest.fileID = configuration.fileID
            confirmationRequest.groupID = configuration.groupID ?? ""
            confirmationRequest.keyID = configuration.encryptionKeyID ?? ""
            confirmationRequest.since = request.since

            let confirmationData = try await client.sync(
                data: try confirmationRequest.serializedData(),
                token: token
            )
            try validateResponseSize(confirmationData)
            let confirmationResponse = try ActualSync_SyncResponse(serializedBytes: confirmationData)
            responseEnvelopes.append(contentsOf: confirmationResponse.messages)
            confirmedTimestamps.formUnion(confirmationResponse.messages.compactMap { envelope in
                pushedEnvelopesByTimestamp[envelope.timestamp] == envelope ? envelope.timestamp : nil
            })
        }

        let unconfirmedCount = pushedEnvelopesByTimestamp.keys.filter {
            !confirmedTimestamps.contains($0)
        }.count
        guard unconfirmedCount == 0 else {
            throw LocalFirstError.syncUploadNotConfirmed(unconfirmedCount)
        }

        var combinedResponse = ActualSync_SyncResponse()
        combinedResponse.messages = Dictionary(
            responseEnvelopes.map { ($0.timestamp, $0) },
            uniquingKeysWith: { _, newest in newest }
        ).values.sorted { $0.timestamp < $1.timestamp }
        let remoteMessages = try decodedMessages(from: combinedResponse, configuration: configuration)
        let applyResult = try await database.applyRemoteSyncMessagesTrackingInserts(remoteMessages)

        return LocalFirstSyncResult(
            pushedMessageCount: messages.count,
            appliedRemoteMessageCount: applyResult.appliedMessageCount,
            insertedTransactionIDsByAccount: applyResult.insertedTransactionIDsByAccount
        )
    }

    private func validateResponseSize(_ data: Data) throws {
        guard data.count <= resourceLimits.maximumSyncResponseBytes else {
            throw LocalFirstError.remoteDataLimitExceeded
        }
    }

    private func decodedMessages(
        from response: ActualSync_SyncResponse,
        configuration: LocalFirstSyncConfiguration
    ) throws -> [ActualSyncDecodedMessage] {
        try auditPlaintextEnvelopes(in: response, configuration: configuration)

        return try response.messages.map { envelope in
            let messageData: Data
            if envelope.isEncrypted {
                guard let encryptionContext = configuration.encryptionContext else {
                    throw LocalFirstError.encryptedBudgetRequiresPassword
                }
                let encryptedData = try ActualSync_EncryptedData(serializedBytes: envelope.content)
                messageData = try ActualBudgetCrypto.decrypt(
                    ActualEncryptedData(
                        data: encryptedData.data,
                        iv: encryptedData.iv,
                        authTag: encryptedData.authTag
                    ),
                    keyData: encryptionContext.keyData
                )
            } else {
                messageData = envelope.content
            }
            let message = try ActualSync_Message(serializedBytes: messageData)
            return ActualSyncDecodedMessage(
                timestamp: envelope.timestamp,
                dataset: message.dataset,
                row: message.row,
                column: message.column,
                serializedValue: message.value
            )
        }
    }

    private func auditPlaintextEnvelopes(
        in response: ActualSync_SyncResponse,
        configuration: LocalFirstSyncConfiguration
    ) throws {
        let budgetUsesEncryption = configuration.encryptionKeyID != nil
            || configuration.encryptionContext != nil
        guard budgetUsesEncryption else {
            return
        }

        let plaintextTimestamps = response.messages
            .filter { !$0.isEncrypted }
            .map(\.timestamp)
            .sorted()
        guard let earliestTimestamp = plaintextTimestamps.first,
              let latestTimestamp = plaintextTimestamps.last else {
            return
        }

        let event = PlaintextEnvelopeAuditEvent(
            budgetIDHash: Self.stableHash(configuration.fileID),
            plaintextMessageCount: plaintextTimestamps.count,
            totalMessageCount: response.messages.count,
            earliestTimestamp: earliestTimestamp,
            latestTimestamp: latestTimestamp,
            hasEncryptionContext: configuration.encryptionContext != nil
        )
        Self.securityLogger.warning(
            """
            Plaintext sync envelopes for encrypted budget: \
            budget_hash=\(event.budgetIDHash, privacy: .public) \
            message_count=\(event.plaintextMessageCount, privacy: .public) \
            total_message_count=\(event.totalMessageCount, privacy: .public) \
            timestamp_range=\(event.earliestTimestamp, privacy: .public)...\(event.latestTimestamp, privacy: .public) \
            encryption_context=\(event.hasEncryptionContext, privacy: .public)
            """
        )
        plaintextEnvelopeAuditRecorder?(event)

        guard !enforcesAuthenticatedEncryptedEnvelopes else {
            throw LocalFirstError.unauthenticatedPlaintextEnvelope
        }
    }

    private static func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
