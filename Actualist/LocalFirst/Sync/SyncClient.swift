import Foundation
import SwiftProtobuf

struct LocalFirstSyncConfiguration: Equatable, Sendable {
    let fileID: String
    let groupID: String?
    let nodeID: String
    let encryptionKeyID: String?
}

actor SyncClient {
    private(set) var configuration: LocalFirstSyncConfiguration?

    func configure(_ configuration: LocalFirstSyncConfiguration) {
        self.configuration = configuration
    }

    func pullAndApply(
        database: BudgetDatabase,
        client: ActualServerSyncClient,
        token: String
    ) async throws -> Int {
        guard let configuration else {
            return 0
        }

        var request = ActualSync_SyncRequest()
        request.fileID = configuration.fileID
        request.groupID = configuration.groupID ?? ""
        request.keyID = configuration.encryptionKeyID ?? ""
        request.since = try database.latestSyncTimestamp()

        let responseData = try await client.sync(data: try request.serializedData(), token: token)
        let response = try ActualSync_SyncResponse(serializedData: responseData)
        let messages = try response.messages.map { envelope in
            guard !envelope.isEncrypted else {
                throw LocalFirstError.encryptedBudgetRequiresPassword
            }
            let message = try ActualSync_Message(serializedData: envelope.content)
            return ActualSyncDecodedMessage(
                timestamp: envelope.timestamp,
                dataset: message.dataset,
                row: message.row,
                column: message.column,
                serializedValue: message.value
            )
        }
        return try database.applyRemoteSyncMessages(messages)
    }
}
