import Foundation
import Testing
@testable import Actualist

/// Registration flow, wire-header, key-material, and store-entry coverage for
/// the portable ZIP registration client. Wire-level request/response coverage
/// lives in PortableBudgetRegistrationWireTests. No server is contacted.
@Suite(.serialized)
struct PortableBudgetRegistrationTests {
    private let fileID = "file-1"
    private let keyID = "key-1"
    private let archiveBytes = Data([0x01, 0x02, 0x03])

    // MARK: - Fixtures

    private func encryptedMeta() -> ActualEncryptedMetadata {
        ActualEncryptedMetadata(
            keyID: keyID,
            algorithm: "aes-256-gcm",
            iv: "aXY=",
            authTag: "dGFn"
        )
    }

    private func encryptedInput(
        fileID: String = "file-1",
        bytes: Data = Data([0x01, 0x02, 0x03])
    ) -> ActualBudgetFileRegistrationInput {
        ActualBudgetFileRegistrationInput(
            fileID: fileID,
            name: "Portable Budget",
            bytes: bytes,
            encryption: .init(
                keyID: keyID,
                keySalt: "salt",
                testContent: "test-content",
                encryptMeta: encryptedMeta()
            )
        )
    }

    private func plaintextInput(fileID: String = "file-1") -> ActualBudgetFileRegistrationInput {
        ActualBudgetFileRegistrationInput(
            fileID: fileID,
            name: "Portable Budget",
            bytes: Data([0x01, 0x02, 0x03]),
            encryption: nil
        )
    }

    private func remoteRow(
        groupID: String? = "group-1",
        meta: ActualEncryptedMetadata? = nil
    ) -> ActualSyncRemoteFile {
        ActualSyncRemoteFile(
            fileID: fileID,
            groupID: groupID,
            name: "Portable Budget",
            deleted: false,
            encryptMeta: meta,
            requiresEncryptionPassword: meta != nil
        )
    }

    private func makeFlow(
        transport: FakeRegistrationTransport,
        recovery: RegistrationRecoveryStub
    ) -> ActualBudgetFileRegistrationFlow {
        ActualBudgetFileRegistrationFlow(
            transport: transport,
            listUserFiles: recovery.listUserFiles,
            userInfo: recovery.userInfo
        )
    }

    // MARK: - Flow: direct confirmation

    @Test func plaintextRegistrationConfirmsGroupFromUploadResponse() async throws {
        let transport = FakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-1"))]
        )
        let recovery = RegistrationRecoveryStub()

        let receipt = try await makeFlow(transport: transport, recovery: recovery)
            .register(plaintextInput(), token: "tok")

        #expect(receipt == ActualBudgetFileRegistrationReceipt(
            fileID: fileID, groupID: "group-1", encryptionKeyID: nil
        ))
        let uploads = await transport.uploads
        #expect(uploads.count == 1)
        #expect(uploads[0] == FakeRegistrationTransport.UploadCall(
            fileID: fileID, name: "Portable Budget", groupID: nil,
            encryptMetaKeyID: nil, byteCount: 3, token: "tok"
        ))
        #expect(await transport.createKeyCalls.isEmpty)
        #expect(recovery.snapshot().listCallCount == 0)
        #expect(recovery.snapshot().infoCalls.isEmpty)
    }

    @Test func encryptedRegistrationUploadsFirstThenRegistersKey() async throws {
        let transport = FakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-1"))]
        )
        let recovery = RegistrationRecoveryStub()

        let receipt = try await makeFlow(transport: transport, recovery: recovery)
            .register(encryptedInput(), token: "tok")

        #expect(receipt == ActualBudgetFileRegistrationReceipt(
            fileID: fileID, groupID: "group-1", encryptionKeyID: keyID
        ))
        #expect(await transport.events == ["upload", "createKey"])
        let uploads = await transport.uploads
        #expect(uploads.count == 1)
        #expect(uploads[0].encryptMetaKeyID == keyID)
        let createKey = try #require(await transport.createKeyCalls.first)
        #expect(createKey == FakeRegistrationTransport.CreateKeyCall(
            fileID: fileID, keyID: keyID, keySalt: "salt",
            testContent: "test-content", token: "tok"
        ))
    }

    @Test func unconfirmedKeyRegistrationThrowsAndNeverReturnsReceipt() async throws {
        let transport = FakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-1"))],
            createKeyError: ActualFileRegistrationError.keyRegistrationNotConfirmed
        )
        let recovery = RegistrationRecoveryStub()

        await #expect(throws: ActualFileRegistrationError.keyRegistrationNotConfirmed) {
            try await makeFlow(transport: transport, recovery: recovery)
                .register(encryptedInput(), token: "tok")
        }
        #expect(await transport.events == ["upload", "createKey", "delete"])
        #expect(await transport.deleteCalls == [fileID])
    }

    // MARK: - Flow: lost-response reconciliation

    @Test func lostUploadResponseRecoversGroupFromListUnderKnownID() async throws {
        let transport = FakeRegistrationTransport(
            uploadResults: [.failure(ActualAPIError.transport(.timedOut))]
        )
        let recovery = RegistrationRecoveryStub(
            listResults: [.success([remoteRow(groupID: "group-1", meta: encryptedMeta())])],
            infoResults: [fileID: remoteRow(groupID: "group-1", meta: encryptedMeta())]
        )

        let receipt = try await makeFlow(transport: transport, recovery: recovery)
            .register(encryptedInput(), token: "tok")

        #expect(receipt == ActualBudgetFileRegistrationReceipt(
            fileID: fileID, groupID: "group-1", encryptionKeyID: keyID
        ))
        // Exactly one upload under the known ID — no second identity minted.
        let uploads = await transport.uploads
        #expect(uploads.count == 1)
        #expect(uploads[0].fileID == fileID)
        #expect(await transport.events == ["upload", "createKey"])
    }

    @Test func lostResponseWithEmptyListRetriesUploadOnceUnderSameID() async throws {
        let transport = FakeRegistrationTransport(uploadResults: [
            .failure(ActualAPIError.transport(.timedOut)),
            .success(ActualUploadUserFileResponse(groupID: "group-2")),
        ])
        let recovery = RegistrationRecoveryStub(listResults: [.success([])])

        let receipt = try await makeFlow(transport: transport, recovery: recovery)
            .register(encryptedInput(), token: "tok")

        #expect(receipt == ActualBudgetFileRegistrationReceipt(
            fileID: fileID, groupID: "group-2", encryptionKeyID: keyID
        ))
        let uploads = await transport.uploads
        #expect(uploads.count == 2)
        #expect(uploads.allSatisfy { $0.fileID == fileID })
        #expect(await transport.events == ["upload", "upload", "createKey"])
    }

    @Test func rejectedRetryFallsBackToFinalListRecovery() async throws {
        let transport = FakeRegistrationTransport(uploadResults: [
            .failure(ActualAPIError.transport(.timedOut)),
            .failure(ActualAPIError.syncRejected(status: 400, reason: .fileHasReset)),
        ])
        let recovery = RegistrationRecoveryStub(
            listResults: [
                .success([]),
                .success([remoteRow(groupID: "group-1", meta: encryptedMeta())]),
            ],
            infoResults: [fileID: remoteRow(groupID: "group-1", meta: encryptedMeta())]
        )

        let receipt = try await makeFlow(transport: transport, recovery: recovery)
            .register(encryptedInput(), token: "tok")

        #expect(receipt == ActualBudgetFileRegistrationReceipt(
            fileID: fileID, groupID: "group-1", encryptionKeyID: keyID
        ))
        let uploads = await transport.uploads
        #expect(uploads.count == 2)
        #expect(uploads.allSatisfy { $0.fileID == fileID })
        #expect(recovery.snapshot().listCallCount == 2)
    }

    @Test func unconfirmableUploadThrowsWithoutMintingASecondID() async throws {
        let transport = FakeRegistrationTransport(
            uploadResults: [.failure(ActualAPIError.transport(.timedOut))]
        )
        let recovery = RegistrationRecoveryStub(listResults: [.success([])])

        await #expect(throws: ActualFileRegistrationError.uploadUnconfirmed) {
            try await makeFlow(transport: transport, recovery: recovery)
                .register(plaintextInput(), token: "tok")
        }
        let uploads = await transport.uploads
        #expect(uploads.count == 2)
        #expect(uploads.allSatisfy { $0.fileID == fileID })
        #expect(recovery.snapshot().listCallCount == 2)
        #expect(await transport.createKeyCalls.isEmpty)
    }

    @Test func ambiguousListRefusesRegistration() async throws {
        let transport = FakeRegistrationTransport()
        let recovery = RegistrationRecoveryStub(listResults: [.success([
            remoteRow(groupID: "group-1"),
            remoteRow(groupID: "group-2"),
        ])])

        await #expect(throws: ActualFileRegistrationError.registrationAmbiguous) {
            try await makeFlow(transport: transport, recovery: recovery)
                .register(plaintextInput(), token: "tok")
        }
        #expect(await transport.uploads.count == 1)
        #expect(await transport.createKeyCalls.isEmpty)
    }

    @Test func recoveredRowWithoutGroupRefusesRegistration() async throws {
        let transport = FakeRegistrationTransport()
        let recovery = RegistrationRecoveryStub(
            listResults: [.success([remoteRow(groupID: nil)])],
            infoResults: [fileID: remoteRow(groupID: nil)]
        )

        await #expect(throws: ActualFileRegistrationError.uploadUnconfirmed) {
            try await makeFlow(transport: transport, recovery: recovery)
                .register(plaintextInput(), token: "tok")
        }
        #expect(await transport.createKeyCalls.isEmpty)
    }

    @Test func deletedListRowsAreIgnoredDuringRecovery() async throws {
        let deletedRow = ActualSyncRemoteFile(
            fileID: fileID, groupID: "group-1", name: "Portable Budget", deleted: true
        )
        let transport = FakeRegistrationTransport()
        let recovery = RegistrationRecoveryStub(listResults: [.success([
            deletedRow,
            remoteRow(groupID: "group-1"),
        ])])

        let receipt = try await makeFlow(transport: transport, recovery: recovery)
            .register(plaintextInput(), token: "tok")

        #expect(receipt == ActualBudgetFileRegistrationReceipt(
            fileID: fileID, groupID: "group-1", encryptionKeyID: nil
        ))
        #expect(await transport.createKeyCalls.isEmpty)
    }

    // MARK: - Flow: encryption consistency on recovery

    @Test func recoveredFileWithDifferentKeyRefusesInsteadOfCorrupting() async throws {
        let otherMeta = ActualEncryptedMetadata(
            keyID: "key-other", algorithm: "aes-256-gcm", iv: "aXY=", authTag: "dGFn"
        )
        let transport = FakeRegistrationTransport()
        let recovery = RegistrationRecoveryStub(
            listResults: [.success([remoteRow(groupID: "group-1", meta: otherMeta)])],
            infoResults: [fileID: remoteRow(groupID: "group-1", meta: otherMeta)]
        )

        await #expect(throws: ActualFileRegistrationError.encryptionKeyMismatch) {
            try await makeFlow(transport: transport, recovery: recovery)
                .register(encryptedInput(), token: "tok")
        }
        // The key is never re-registered over bytes it cannot open.
        #expect(await transport.createKeyCalls.isEmpty)
        #expect(recovery.snapshot().infoCalls == [fileID])
    }

    @Test func recoveredPlaintextFileWithRemoteMetaRefusesEncryptedReceipt() async throws {
        let transport = FakeRegistrationTransport()
        let recovery = RegistrationRecoveryStub(
            listResults: [.success([remoteRow(groupID: "group-1", meta: encryptedMeta())])],
            infoResults: [fileID: remoteRow(groupID: "group-1", meta: encryptedMeta())]
        )

        await #expect(throws: ActualFileRegistrationError.encryptionKeyMismatch) {
            try await makeFlow(transport: transport, recovery: recovery)
                .register(plaintextInput(), token: "tok")
        }
        #expect(await transport.createKeyCalls.isEmpty)
    }

    @Test func emptyRegistrationInputIsRefusedBeforeAnyRequest() async throws {
        let transport = FakeRegistrationTransport()
        let recovery = RegistrationRecoveryStub()

        await #expect(throws: ActualFileRegistrationError.emptyRegistrationInput) {
            try await makeFlow(transport: transport, recovery: recovery)
                .register(plaintextInput(fileID: ""), token: "tok")
        }
        #expect(await transport.uploads.isEmpty)
        #expect(recovery.snapshot().listCallCount == 0)
    }

    // MARK: - Key material builder

    @Test func keySetRoundTripsThroughActualKeyValidation() throws {
        let bytes = Data("portable-archive-bytes".utf8)
        let keySet = try ActualBudgetRegistrationKeySet.make(
            password: "secret-passphrase",
            archiveBytes: bytes,
            keyID: keyID
        )

        #expect(keySet.keyID == keyID)
        #expect(keySet.encryptMeta.keyID == keyID)
        #expect(keySet.encryptMeta.algorithm == ActualBudgetCrypto.algorithm)
        let saltBytes = try #require(Data(base64Encoded: keySet.salt))
        #expect(saltBytes.count == 32)

        // The archive ciphertext decrypts with the derived key.
        let decrypted = try ActualBudgetCrypto.decrypt(
            try keySet.encryptMeta.encryptedData(keySet.encryptedArchiveBytes),
            keyData: keySet.keyData
        )
        #expect(decrypted == bytes)

        // The test content is the exact envelope Actual's key-test reads and
        // validates through the same password path the app uses on open.
        let keyResponse = ActualUserKeyResponse(id: keySet.keyID, salt: keySet.salt, test: keySet.testContent)
        let context = try ActualBudgetCrypto.validateUserKeyResponse(keyResponse, password: "secret-passphrase")
        #expect(context.keyID == keySet.keyID)
        #expect(context.keyData == keySet.keyData)
        let testPayload = try JSONDecoder().decode(ActualUserKeyResponse.TestPayload.self, from: Data(keySet.testContent.utf8))
        let testPlaintext = try ActualBudgetCrypto.decrypt(try testPayload.encryptedData(), keyData: keySet.keyData)
        #expect(testPlaintext == Data(ActualBudgetRegistrationKeySet.keyTestPlaintext.utf8))
    }

    @Test func keySetRefusesEmptyPassword() {
        #expect(throws: LocalFirstError.missingPassword) {
            try ActualBudgetRegistrationKeySet.make(password: "", archiveBytes: Data([0x01]))
        }
    }

    // MARK: - Store entry

    @MainActor
    @Test func registerPortableBudgetUploadsKnownIDAndSavesConfirmedKey() async throws {
        let backend = FakeKeychainBackend()
        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: "test.actualist", account: "sync-token", backend: backend)
        )
        try store.keychain.saveActualSyncToken("session-token")
        let transport = FakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-1"))]
        )
        let recovery = RegistrationRecoveryStub()

        let receipt = try await store.registerPortableBudget(
            archiveBytes: archiveBytes,
            budgetName: "Portable Budget",
            knownFileID: fileID,
            serverURLString: "https://registration.example",
            encryptionPassword: "secret-passphrase",
            token: "session-token",
            registrationTransport: transport,
            listUserFiles: recovery.listUserFiles,
            userInfo: recovery.userInfo
        )

        #expect(receipt.fileID == fileID)
        #expect(receipt.groupID == "group-1")
        let registeredKeyID = try #require(receipt.encryptionKeyID)
        let uploads = await transport.uploads
        #expect(uploads.count == 1)
        #expect(uploads[0].fileID == fileID)
        #expect(uploads[0].token == "session-token")
        let savedKey = try store.keychain.readLocalFirstEncryptionKey(fileID: fileID, keyID: registeredKeyID)
        #expect(savedKey != nil)
        #expect(savedKey?.count == 32)
    }

    @MainActor
    @Test func registerPortableBudgetPlaintextSkipsKeyRegistrationAndStorage() async throws {
        let backend = FakeKeychainBackend()
        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: "test.actualist", account: "sync-token", backend: backend)
        )
        try store.keychain.saveActualSyncToken("session-token")
        let transport = FakeRegistrationTransport(
            uploadResults: [.success(ActualUploadUserFileResponse(groupID: "group-1"))]
        )
        let recovery = RegistrationRecoveryStub()

        let receipt = try await store.registerPortableBudget(
            archiveBytes: archiveBytes,
            budgetName: "Portable Budget",
            knownFileID: fileID,
            serverURLString: "https://registration.example",
            encryptionPassword: nil,
            token: "session-token",
            registrationTransport: transport,
            listUserFiles: recovery.listUserFiles,
            userInfo: recovery.userInfo
        )

        #expect(receipt.encryptionKeyID == nil)
        #expect(await transport.createKeyCalls.isEmpty)
        #expect(await transport.uploads.count == 1)
    }

    @MainActor
    @Test func registerPortableBudgetRefusesBlankEncryptionPassword() async throws {
        let backend = FakeKeychainBackend()
        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: "test.actualist", account: "sync-token", backend: backend)
        )
        try store.keychain.saveActualSyncToken("session-token")

        await #expect(throws: LocalFirstError.encryptedBudgetRequiresPassword) {
            try await store.registerPortableBudget(
                archiveBytes: archiveBytes,
                budgetName: "Portable Budget",
                knownFileID: fileID,
                serverURLString: "https://registration.example",
                encryptionPassword: "   ",
                token: "session-token",
                registrationTransport: FakeRegistrationTransport()
            )
        }
    }

    @MainActor
    @Test func registerPortableBudgetRequiresStoredToken() async {
        let backend = FakeKeychainBackend()
        let store = LocalFirstActualStore(
            keychain: KeychainStore(service: "test.actualist", account: "sync-token", backend: backend)
        )

        await #expect(throws: LocalFirstError.missingSyncToken) {
            try await store.registerPortableBudget(
                archiveBytes: archiveBytes,
                budgetName: "Portable Budget",
                knownFileID: fileID,
                serverURLString: "https://registration.example",
                encryptionPassword: nil
            )
        }
    }
}

// MARK: - Fakes

/// Queue-driven fake with sticky-last semantics: the final result repeats for
/// any further calls, so single-entry queues cover retry paths.
private actor FakeRegistrationTransport: ActualFileRegistrationTransport {
    struct UploadCall: Equatable {
        let fileID: String
        let name: String
        let groupID: String?
        let encryptMetaKeyID: String?
        let byteCount: Int
        let token: String
    }

    struct CreateKeyCall: Equatable {
        let fileID: String
        let keyID: String
        let keySalt: String
        let testContent: String
        let token: String
    }

    private var uploadResults: [Result<ActualUploadUserFileResponse, Error>]
    private let createKeyError: Error?
    private(set) var uploads: [UploadCall] = []
    private(set) var createKeyCalls: [CreateKeyCall] = []
    private(set) var events: [String] = []
    private(set) var deleteCalls: [String] = []

    init(
        uploadResults: [Result<ActualUploadUserFileResponse, Error>] = [],
        createKeyError: Error? = nil
    ) {
        self.uploadResults = uploadResults
        self.createKeyError = createKeyError
    }

    func uploadUserFile(
        fileID: String,
        name: String,
        groupID: String?,
        encryptMeta: ActualEncryptedMetadata?,
        bytes: Data,
        token: String
    ) async throws -> ActualUploadUserFileResponse {
        uploads.append(UploadCall(
            fileID: fileID, name: name, groupID: groupID,
            encryptMetaKeyID: encryptMeta?.keyID, byteCount: bytes.count, token: token
        ))
        events.append("upload")
        let result: Result<ActualUploadUserFileResponse, Error>
        if uploadResults.isEmpty {
            result = .success(ActualUploadUserFileResponse(groupID: nil))
        } else if uploadResults.count == 1 {
            result = uploadResults[0]
        } else {
            result = uploadResults.removeFirst()
        }
        return try result.get()
    }

    func createUserKey(
        fileID: String,
        keyID: String,
        keySalt: String,
        testContent: String,
        token: String
    ) async throws {
        createKeyCalls.append(CreateKeyCall(
            fileID: fileID, keyID: keyID, keySalt: keySalt,
            testContent: testContent, token: token
        ))
        events.append("createKey")
        if let createKeyError { throw createKeyError }
    }

    func deleteUserFile(fileID: String, token: String) async throws {
        deleteCalls.append(fileID)
        events.append("delete")
    }
}

/// Lock-protected fake for the existing list-user-files / get-user-file-info
/// recovery paths, with the same sticky-last queue semantics.
private final class RegistrationRecoveryStub: @unchecked Sendable {
    private let lock = NSLock()
    private var listResults: [Result<[ActualSyncRemoteFile], Error>]
    private var infoResults: [String: Result<ActualSyncRemoteFile?, Error>]
    private var listCallCount = 0
    private var infoCallFileIDs: [String] = []

    init(
        listResults: [Result<[ActualSyncRemoteFile], Error>] = [],
        infoResults: [String: ActualSyncRemoteFile?] = [:]
    ) {
        self.listResults = listResults
        self.infoResults = infoResults.mapValues { .success($0) }
    }

    func snapshot() -> (listCallCount: Int, infoCalls: [String]) {
        lock.withLock { (listCallCount, infoCallFileIDs) }
    }

    var listUserFiles: @Sendable (String) async throws -> [ActualSyncRemoteFile] {
        { [self] _ in
            try lock.withLock {
                listCallCount += 1
                let result: Result<[ActualSyncRemoteFile], Error>
                if listResults.isEmpty {
                    result = .success([])
                } else if listResults.count == 1 {
                    result = listResults[0]
                } else {
                    result = listResults.removeFirst()
                }
                return try result.get()
            }
        }
    }

    var userInfo: @Sendable (String, String) async throws -> ActualSyncRemoteFile? {
        { [self] fileID, _ in
            try lock.withLock {
                infoCallFileIDs.append(fileID)
                return try infoResults[fileID]?.get() ?? nil
            }
        }
    }
}
