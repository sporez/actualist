import Foundation

extension LocalFirstActualStore {
    /// Registers an already validated portable archive as a new file on the
    /// Actual server. The caller owns archive validation
    /// (`PortableBudgetArchive`) and mints `knownFileID` exactly once; this
    /// entry never generates a second identity for the same budget, and a
    /// failed upload never becomes a local budget — the receipt is only
    /// returned after the server confirmed the file (and, for encrypted
    /// archives, its key registration).
    ///
    /// Pass `encryptionPassword` only for a deliberately encrypted archive;
    /// a non-nil password that trims to empty is refused rather than silently
    /// registered as plaintext. Retrying after `uploadUnconfirmed` must reuse
    /// the same `knownFileID` and encryption inputs; the recovery path
    /// refuses a different key over already-stored bytes instead of
    /// corrupting them.
    func registerPortableBudget(
        archiveBytes: Data,
        budgetName: String,
        knownFileID: String,
        serverURLString: String,
        encryptionPassword: String?
    ) async throws -> ActualBudgetFileRegistrationReceipt {
        let token = try keychain.readActualSyncToken()
        guard let token else {
            throw LocalFirstError.missingSyncToken
        }
        return try await registerPortableBudget(
            archiveBytes: archiveBytes,
            budgetName: budgetName,
            knownFileID: knownFileID,
            serverURLString: serverURLString,
            encryptionPassword: encryptionPassword,
            token: token
        )
    }

    /// Test seam: explicit token, transport, and recovery paths. Production
    /// callers use the overload above.
    func registerPortableBudget(
        archiveBytes: Data,
        budgetName: String,
        knownFileID: String,
        serverURLString: String,
        encryptionPassword: String?,
        token: String,
        registrationTransport: (any ActualFileRegistrationTransport)? = nil,
        listUserFiles: (@Sendable (String) async throws -> [ActualSyncRemoteFile])? = nil,
        userInfo: (@Sendable (String, String) async throws -> ActualSyncRemoteFile?)? = nil
    ) async throws -> ActualBudgetFileRegistrationReceipt {
        let transport = try registrationTransport ?? makeRegistrationTransport(serverURLString: serverURLString)
        let recoveryList: @Sendable (String) async throws -> [ActualSyncRemoteFile]
        let recoveryInfo: @Sendable (String, String) async throws -> ActualSyncRemoteFile?
        if let listUserFiles {
            recoveryList = listUserFiles
        } else {
            // The existing list-user-files path, including connection failover.
            recoveryList = { [self] token in
                try await withConnectionFailover(serverURLString: serverURLString) { client in
                    try await client.listUserFiles(token: token)
                }
            }
        }
        if let userInfo {
            recoveryInfo = userInfo
        } else {
            recoveryInfo = { [self] fileID, token in
                try await withConnectionFailover(serverURLString: serverURLString) { client in
                    try await client.userFileInfo(fileID: fileID, token: token)
                }
            }
        }
        let flow = ActualBudgetFileRegistrationFlow(
            transport: transport,
            listUserFiles: recoveryList,
            userInfo: recoveryInfo
        )

        let keySet: ActualBudgetRegistrationKeySet?
        if encryptionPassword != nil {
            guard let password = encryptionPassword?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !password.isEmpty else {
                throw LocalFirstError.encryptedBudgetRequiresPassword
            }
            keySet = try ActualBudgetRegistrationKeySet.make(
                password: password,
                archiveBytes: archiveBytes
            )
        } else {
            keySet = nil
        }

        let input = ActualBudgetFileRegistrationInput(
            fileID: knownFileID,
            name: budgetName,
            bytes: keySet?.encryptedArchiveBytes ?? archiveBytes,
            encryption: keySet.map { keySet in
                ActualBudgetFileRegistrationInput.Encryption(
                    keyID: keySet.keyID,
                    keySalt: keySet.salt,
                    testContent: keySet.testContent,
                    encryptMeta: keySet.encryptMeta
                )
            }
        )
        let receipt = try await flow.register(input, token: token)

        // Persist the unlocked key only after the server confirmed both the
        // upload and the key registration.
        if let keySet {
            try keychain.saveLocalFirstEncryptionKey(
                keySet.keyData,
                fileID: knownFileID,
                keyID: keySet.keyID
            )
        }
        return receipt
    }

    private func makeRegistrationTransport(
        serverURLString: String
    ) throws -> any ActualFileRegistrationTransport {
        guard let serverURL = failoverEndpoints(for: serverURLString).primary else {
            throw ActualAPIError.invalidURL
        }
        let fields = try keychain.readCustomHTTPHeaders().fields(for: .primary, url: serverURL)
        return ActualServerFileRegistrationClient(
            baseURL: serverURL,
            customHeaders: fields,
            session: transportSession
        )
    }
}
