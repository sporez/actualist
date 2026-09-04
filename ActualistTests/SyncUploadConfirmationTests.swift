import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test(arguments: [1, 2])
    func encryptedUploadRetryDrainsOutboxAfterLostResponse(lostResponseAtCall: Int) async throws {
        let transport = RecordingSyncTransport(lostResponseAtCall: lostResponseAtCall)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let context = uploadConfirmationEncryptionContext
        bundle.store.openedEncryptionContext = context
        await bundle.store.syncClient.configure(uploadConfirmationConfiguration(context: context))

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        #expect(pendingCount > 0)

        await #expect(throws: LocalFirstTestSyncError.failed) {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
        }
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingCount)

        try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")

        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError == nil)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastUploadedMessageCount == pendingCount)
    }

    @Test(arguments: [false, true])
    func uploadConfirmationRejectsDifferentContent(encrypted: Bool) async throws {
        let context = encrypted ? uploadConfirmationEncryptionContext : nil
        let sent = uploadConfirmationMessage(value: "S:groceries")
        let different = uploadConfirmationMessage(value: "S:utilities")
        let envelope = try LocalFirstSyncMessageBuilder.envelope(for: different, encryptionContext: context)
        await #expect(throws: LocalFirstError.syncUploadNotConfirmed(1)) {
            try await attemptUploadConfirmation(message: sent, response: envelope, context: context)
        }
    }

    @Test func encryptedUploadConfirmationRejectsPlaintextCopy() async throws {
        let message = uploadConfirmationMessage(value: "S:groceries")
        let envelope = try LocalFirstSyncMessageBuilder.envelope(for: message)
        await #expect(throws: LocalFirstError.syncUploadNotConfirmed(1)) {
            try await attemptUploadConfirmation(
                message: message,
                response: envelope,
                context: uploadConfirmationEncryptionContext
            )
        }
    }

    @Test func encryptedUploadConfirmationAuthenticatesReturnedContent() async throws {
        let message = uploadConfirmationMessage(value: "S:groceries")
        let context = uploadConfirmationEncryptionContext
        var envelope = try LocalFirstSyncMessageBuilder.envelope(for: message, encryptionContext: context)
        var encrypted = try ActualSync_EncryptedData(serializedBytes: envelope.content)
        encrypted.authTag[0] ^= 1
        envelope.content = try encrypted.serializedData()

        await #expect(throws: LocalFirstError.invalidEncryptionPassword) {
            try await attemptUploadConfirmation(message: message, response: envelope, context: context)
        }
    }

    private var uploadConfirmationEncryptionContext: ActualBudgetEncryptionContext {
        ActualBudgetEncryptionContext(keyID: "test-key", keyData: Data(repeating: 7, count: 32))
    }

    private func uploadConfirmationConfiguration(
        context: ActualBudgetEncryptionContext?
    ) -> LocalFirstSyncConfiguration {
        LocalFirstSyncConfiguration(
            fileID: "file-1",
            groupID: "group-1",
            nodeID: "node1",
            encryptionKeyID: context?.keyID,
            encryptionContext: context
        )
    }

    private func uploadConfirmationMessage(value: String) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: value
        )
    }

    private func attemptUploadConfirmation(
        message: ActualSyncDecodedMessage,
        response envelope: ActualSync_MessageEnvelope,
        context: ActualBudgetEncryptionContext?
    ) async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let client = SyncClient()
        await client.configure(uploadConfirmationConfiguration(context: context))
        var response = ActualSync_SyncResponse()
        response.messages = [envelope]
        _ = try await client.pushAndPull(
            database: database,
            client: FixedResponseSyncTransport(responseData: try response.serializedData()),
            token: "token",
            messages: [message],
            since: "1970-01-01T00:00:00.000Z-0000-0000000000000000"
        )
    }
}
