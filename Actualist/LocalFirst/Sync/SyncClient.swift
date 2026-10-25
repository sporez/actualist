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
    /// Timestamps of remote values stored but not applied because they were unreadable.
    let quarantinedTimestamps: [String]
    /// The endpoint the store used for this operation. Set by the store's sync
    /// lane, not by the sync client, so it never reflects a concurrent attempt.
    var endpoint: LocalFirstSyncDebugEvent.Endpoint?

    init(
        pushedMessageCount: Int,
        appliedRemoteMessageCount: Int,
        insertedTransactionIDsByAccount: [String: [String]] = [:],
        quarantinedTimestamps: [String] = [],
        endpoint: LocalFirstSyncDebugEvent.Endpoint? = nil
    ) {
        self.endpoint = endpoint
        self.pushedMessageCount = pushedMessageCount
        self.appliedRemoteMessageCount = appliedRemoteMessageCount
        self.insertedTransactionIDsByAccount = insertedTransactionIDsByAccount
        self.quarantinedTimestamps = quarantinedTimestamps
    }
}

actor SyncClient {
    private static let securityLogger = Logger(
        subsystem: "com.sporez.actualist",
        category: "SyncSecurity"
    )

    private(set) var configuration: LocalFirstSyncConfiguration?
    private var sessionGeneration = 0
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

    func configure(_ configuration: LocalFirstSyncConfiguration, generation: Int? = nil) {
        if let generation {
            guard generation >= sessionGeneration else { return }
            sessionGeneration = generation
        }
        self.configuration = configuration
    }

    func invalidate(generation: Int) {
        guard generation >= sessionGeneration else { return }
        sessionGeneration = generation
        configuration = nil
    }

    func pullAndApply(
        database: BudgetDatabase,
        client: any ActualSyncTransport,
        token: String,
        sessionIsCurrent: @escaping @Sendable () async -> Bool,
        appliedRecorder: PartialSyncApplyRecorder? = nil
    ) async throws -> BudgetDatabase.RemoteSyncApplyResult {
        guard let configuration else {
            throw LocalFirstError.budgetNotOpened
        }
        let generation = sessionGeneration

        var request = ActualSync_SyncRequest()
        request.fileID = configuration.fileID
        request.groupID = configuration.groupID ?? ""
        request.keyID = configuration.encryptionKeyID ?? ""
        request.since = try await database.latestSyncTimestamp()
        try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)

        let clockBefore = await database.localClockTimestamp
        let responseData = try await client.sync(data: try request.serializedData(), token: token)
        try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
        try validateResponseSize(responseData)
        let response = try ActualSync_SyncResponse(serializedBytes: responseData)
        let messages = try decodedMessages(from: response, configuration: configuration)
        let localTimeChanged = await database.localClockTimestamp != clockBefore
        let applied = try await database.applyRemoteSyncMessagesTrackingInserts(messages)
        await appliedRecorder?.record(applied)
        try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
        return try await repullUntilMerkleMatches(
            applied,
            serverMerkle: response.merkle,
            localTimeChanged: localTimeChanged,
            database: database,
            client: client,
            token: token,
            configuration: configuration,
            generation: generation,
            sessionIsCurrent: sessionIsCurrent,
            appliedRecorder: appliedRecorder
        )
    }

    func pushAndPull(
        database: BudgetDatabase,
        client: any ActualSyncTransport,
        token: String,
        messages: [ActualSyncDecodedMessage],
        since: String? = nil,
        sessionIsCurrent: @escaping @Sendable () async -> Bool,
        onUploadConfirmed: (@Sendable () async throws -> Void)? = nil,
        appliedRecorder: PartialSyncApplyRecorder? = nil
    ) async throws -> LocalFirstSyncResult {
        guard let configuration else {
            throw LocalFirstError.budgetNotOpened
        }
        let generation = sessionGeneration

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
        try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)

        let clockBefore = await database.localClockTimestamp
        let responseData = try await client.sync(data: try request.serializedData(), token: token)
        try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
        try validateResponseSize(responseData)
        let response = try ActualSync_SyncResponse(serializedBytes: responseData)
        var responseEnvelopes = response.messages
        var confirmationMerkle: String?
        let pushedEnvelopesByTimestamp = Dictionary(
            request.messages.map { ($0.timestamp, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        var confirmedTimestamps = try confirmedUploadTimestamps(
            in: responseEnvelopes,
            matching: pushedEnvelopesByTimestamp,
            configuration: configuration
        )

        // The server reads before inserting this upload, so confirm it with a second pull.
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
            try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
            try validateResponseSize(confirmationData)
            let confirmationResponse = try ActualSync_SyncResponse(serializedBytes: confirmationData)
            responseEnvelopes.append(contentsOf: confirmationResponse.messages)
            confirmationMerkle = confirmationResponse.merkle
            confirmedTimestamps.formUnion(try confirmedUploadTimestamps(
                in: confirmationResponse.messages,
                matching: pushedEnvelopesByTimestamp,
                configuration: configuration
            ))
        }

        let unconfirmedCount = pushedEnvelopesByTimestamp.keys.filter {
            !confirmedTimestamps.contains($0)
        }.count
        guard unconfirmedCount == 0 else {
            throw LocalFirstError.syncUploadNotConfirmed(unconfirmedCount)
        }
        // The server holds the upload now. Report it before the merkle re-pull below,
        // whose failure must not leave confirmed messages queued for another upload.
        try await onUploadConfirmed?()

        var combinedResponse = ActualSync_SyncResponse()
        combinedResponse.messages = Dictionary(
            responseEnvelopes.map { ($0.timestamp, $0) },
            uniquingKeysWith: { _, newest in newest }
        ).values.sorted { $0.timestamp < $1.timestamp }
        let remoteMessages = try decodedMessages(from: combinedResponse, configuration: configuration)
        let localTimeChanged = await database.localClockTimestamp != clockBefore
        let firstApply = try await database.applyRemoteSyncMessagesTrackingInserts(remoteMessages)
        await appliedRecorder?.record(firstApply)
        try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
        let applyResult = try await repullUntilMerkleMatches(
            firstApply,
            serverMerkle: confirmationMerkle ?? response.merkle,
            localTimeChanged: localTimeChanged,
            database: database,
            client: client,
            token: token,
            configuration: configuration,
            generation: generation,
            sessionIsCurrent: sessionIsCurrent,
            appliedRecorder: appliedRecorder
        )

        return LocalFirstSyncResult(
            pushedMessageCount: messages.count,
            appliedRemoteMessageCount: applyResult.appliedMessageCount,
            insertedTransactionIDsByAccount: applyResult.insertedTransactionIDsByAccount,
            quarantinedTimestamps: applyResult.quarantinedTimestamps
        )
    }

    /// Upstream `_fullSync`'s loop: after applying a pull, compare the server's
    /// merkle with this file's and run another round from the first differing
    /// minute until they match. Each round re-sends this file's messages after
    /// that minute and pulls the server's (`resendRound`), so older messages from
    /// other devices arrive and messages the server lacks reach it.
    private func repullUntilMerkleMatches(
        _ initial: BudgetDatabase.RemoteSyncApplyResult,
        serverMerkle initialMerkle: String,
        localTimeChanged initialLocalChange: Bool,
        database: BudgetDatabase,
        client: any ActualSyncTransport,
        token: String,
        configuration: LocalFirstSyncConfiguration,
        generation: Int,
        sessionIsCurrent: @escaping @Sendable () async -> Bool,
        appliedRecorder: PartialSyncApplyRecorder?
    ) async throws -> BudgetDatabase.RemoteSyncApplyResult {
        var total = initial
        var server = MerkleTrie(jsonString: initialMerkle)
        var count = initialLocalChange ? 0 : 1
        var previousDivergence: Int64?
        var rebuilt = false
        while true {
            try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
            // An empty or unreadable server merkle (older servers) skips the comparison.
            guard let serverTrie = server,
                  let divergence = try await database.merkleDivergence(from: serverTrie) else {
                return total
            }
            if (count >= 10 && divergence == previousDivergence) || count >= 100 {
                // Upstream rebuilds the trie before giving up: a stale stored trie is
                // a cheaper explanation than a diverged history.
                guard !rebuilt else { throw LocalFirstError.syncOutOfSync }
                rebuilt = true
                try await database.rebuildMerkleTrie()
                count = 0
                previousDivergence = nil
                continue
            }

            let since = SyncTimestamp.wallTimeString(
                for: Date(timeIntervalSince1970: Double(divergence) / 1_000)
            ) + "-0000-0000000000000000"
            let round = try await resendRound(
                since: since,
                database: database,
                client: client,
                token: token,
                configuration: configuration,
                generation: generation,
                sessionIsCurrent: sessionIsCurrent,
                appliedRecorder: appliedRecorder
            )
            total = total.merging(round.applied)
            server = MerkleTrie(jsonString: round.merkle)
            count = round.localTimeChanged ? 0 : count + 1
            previousDivergence = divergence
        }
    }

    /// One `_fullSync` round from the divergence: like upstream, it sends every
    /// `messages_crdt` row after `since` (local and remote alike; the server
    /// ignores a timestamp it already holds), so messages this file holds that
    /// the server lacks, such as later outbox batches or a commit made during
    /// the sync, close the divergence. Upstream sends them in one request; here
    /// they go in pages of `BudgetDatabase.syncUploadBatchLimit`, the outbox
    /// upload size. Only the first page asks for the server's messages since the
    /// divergence; later pages ask from this file's newest so the same messages
    /// are not returned again. The last response's merkle decides the round.
    private func resendRound(
        since: String,
        database: BudgetDatabase,
        client: any ActualSyncTransport,
        token: String,
        configuration: LocalFirstSyncConfiguration,
        generation: Int,
        sessionIsCurrent: @escaping @Sendable () async -> Bool,
        appliedRecorder: PartialSyncApplyRecorder?
    ) async throws -> (applied: BudgetDatabase.RemoteSyncApplyResult, merkle: String, localTimeChanged: Bool) {
        var applied = BudgetDatabase.RemoteSyncApplyResult.empty
        var localTimeChanged = false
        var requestSince = since
        var cursor = since
        var isFirstPage = true
        var merkle = ""
        while true {
            let page = try await database.crdtMessagePage(after: cursor, limit: BudgetDatabase.syncUploadBatchLimit)
            guard isFirstPage || page.rowCount > 0 else { break }
            var request = ActualSync_SyncRequest()
            request.fileID = configuration.fileID
            request.groupID = configuration.groupID ?? ""
            request.keyID = configuration.encryptionKeyID ?? ""
            request.since = requestSince
            request.messages = try LocalFirstSyncMessageBuilder.envelopes(
                for: page.messages,
                encryptionContext: configuration.encryptionContext
            )
            try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
            let clockBefore = await database.localClockTimestamp
            let responseData = try await client.sync(data: try request.serializedData(), token: token)
            try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
            try validateResponseSize(responseData)
            let response = try ActualSync_SyncResponse(serializedBytes: responseData)
            let messages = try decodedMessages(from: response, configuration: configuration)
            // Like upstream, a local commit during the request is not a failed attempt.
            // Read before applying: applying remote messages also advances the clock.
            if await database.localClockTimestamp != clockBefore {
                localTimeChanged = true
            }
            let pageApplied = try await database.applyRemoteSyncMessagesTrackingInserts(messages)
            await appliedRecorder?.record(pageApplied)
            applied = applied.merging(pageApplied)
            try await requireActiveSession(generation: generation, sessionIsCurrent: sessionIsCurrent)
            merkle = response.merkle

            guard page.rowCount == BudgetDatabase.syncUploadBatchLimit, let last = page.lastTimestamp else { break }
            cursor = last
            requestSince = try await database.latestSyncTimestamp()
            isFirstPage = false
        }
        return (applied, merkle, localTimeChanged)
    }


    /// Backstop for transports that do not enforce the cap while reading. It
    /// throws the same typed error as the HTTP client's chunked reader, so a
    /// catch-up that is too large reads the same however it was detected.
    private func validateResponseSize(_ data: Data) throws {
        guard data.count <= resourceLimits.maximumSyncResponseBytes else {
            throw ActualAPIError.syncCatchUpTooLarge
        }
    }

    private func requireActiveSession(
        generation: Int,
        sessionIsCurrent: @escaping @Sendable () async -> Bool
    ) async throws {
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
        guard await sessionIsCurrent(), generation == sessionGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func confirmedUploadTimestamps(
        in envelopes: [ActualSync_MessageEnvelope],
        matching uploaded: [String: ActualSync_MessageEnvelope],
        configuration: LocalFirstSyncConfiguration
    ) throws -> Set<String> {
        var confirmed = Set<String>()
        for envelope in envelopes {
            guard let expected = uploaded[envelope.timestamp] else { continue }
            if envelope == expected {
                confirmed.insert(envelope.timestamp)
            } else if envelope.isEncrypted && expected.isEncrypted {
                // Actual keeps the first envelope for a timestamp. A retry uses a fresh IV,
                // so authenticate and compare message content instead of encrypted bytes.
                let returnedMessage = try decodedMessage(from: envelope, configuration: configuration)
                let uploadedMessage = try decodedMessage(from: expected, configuration: configuration)
                if returnedMessage == uploadedMessage {
                    confirmed.insert(envelope.timestamp)
                }
            }
        }
        return confirmed
    }

    private func decodedMessages(
        from response: ActualSync_SyncResponse,
        configuration: LocalFirstSyncConfiguration
    ) throws -> [ActualSyncDecodedMessage] {
        try auditPlaintextEnvelopes(in: response, configuration: configuration)

        return try response.messages.map {
            try decodedMessage(from: $0, configuration: configuration)
        }
    }

    private func decodedMessage(
        from envelope: ActualSync_MessageEnvelope,
        configuration: LocalFirstSyncConfiguration
    ) throws -> ActualSyncDecodedMessage {
        let messageData: Data
        if envelope.isEncrypted {
            guard let encryptionContext = configuration.encryptionContext else {
                throw LocalFirstError.encryptedBudgetRequiresPassword
            }
            do {
                let encryptedData = try ActualSync_EncryptedData(serializedBytes: envelope.content)
                messageData = try ActualBudgetCrypto.decrypt(
                    ActualEncryptedData(
                        data: encryptedData.data,
                        iv: encryptedData.iv,
                        authTag: encryptedData.authTag
                    ),
                    keyData: encryptionContext.keyData
                )
            } catch {
                throw LocalFirstError.undecryptableMessage
            }
        } else {
            messageData = envelope.content
        }
        let message: ActualSync_Message
        do {
            message = try ActualSync_Message(serializedBytes: messageData)
        } catch {
            throw LocalFirstError.undecryptableMessage
        }
        return ActualSyncDecodedMessage(
            timestamp: envelope.timestamp,
            dataset: message.dataset,
            row: message.row,
            column: message.column,
            serializedValue: message.value
        )
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
