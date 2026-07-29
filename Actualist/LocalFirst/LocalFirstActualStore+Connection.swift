import Foundation

struct StagedLocalFirstConnection {
    let token: String
    let budgets: [ActualBudget]
    let remoteFilesByFileID: [String: ActualSyncRemoteFile]
}

extension LocalFirstActualStore {
    func stageConnection(
        serverURLString: String,
        password: String,
        selectedBudgetID: String?
    ) async throws -> StagedLocalFirstConnection {
        let serverURLString = ActualServerURLNormalizer.normalize(serverURLString)
        guard let baseURL = URL(string: serverURLString) else {
            throw ActualAPIError.invalidURL
        }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalFirstError.missingPassword
        }

        let client = connectionTransportFactory(baseURL)
        _ = try await client.loginMethods()
        let response = try await client.login(password: password)
        let files = try await client.listUserFiles(token: response.token)
        guard !files.isEmpty else {
            throw LocalFirstError.noBudgetsAvailable
        }

        let budgets = files.map(\.actualBudget)
        if let selectedBudgetID,
           !budgets.contains(where: { $0.syncID == selectedBudgetID }) {
            throw LocalFirstError.selectedBudgetUnavailable
        }

        return StagedLocalFirstConnection(
            token: response.token,
            budgets: budgets,
            remoteFilesByFileID: files.reduce(into: [:]) { cache, file in
                cache[file.fileID] = file
            }
        )
    }

    func commitConnection(_ staged: StagedLocalFirstConnection) throws {
        try keychain.saveActualSyncToken(staged.token)
        remoteFilesByFileID = staged.remoteFilesByFileID
        cachedBudgets = staged.budgets
    }

    func loadBudgets(serverURLString: String) async throws -> [ActualBudget] {
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }

        let client = connectionTransportFactory(baseURL)
        let files = try await client.listUserFiles(token: token)
        remoteFilesByFileID = files.reduce(into: [:]) { cache, file in
            cache[file.fileID] = file
        }
        cachedBudgets = files.map(\.actualBudget)
        return cachedBudgets
    }

    func openBudget(
        _ budget: ActualBudget,
        serverURLString: String,
        encryptionPassword: String? = nil
    ) async throws {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }

        // Already open for this budget: refresh in place instead of reopening the DB
        // connection and re-listing files.
        if openedBudgetID == budget.syncID, database != nil {
            openedServerURLString = serverURLString
            try await refresh(budgetID: budget.syncID, serverURLString: serverURLString)
            return
        }

        if fileManager.importedDatabaseExists(fileID: fileID),
           let metadata = try fileManager.loadMetadata(fileID: fileID) {
            do {
                try await openImportedBudget(fileID: fileID, metadata: metadata)
            } catch LocalFirstError.encryptedBudgetRequiresPassword {
                guard let encryptionPassword,
                      !encryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LocalFirstError.encryptedBudgetRequiresPassword
                }
                let token = keychain.readActualSyncToken()
                guard !token.isEmpty else {
                    throw LocalFirstError.missingSyncToken
                }
                guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
                    throw ActualAPIError.invalidURL
                }
                let client = connectionTransportFactory(baseURL)
                let context = try await encryptionContext(
                    metadata: metadata,
                    client: client,
                    token: token,
                    password: encryptionPassword
                )
                try await openImportedBudget(fileID: fileID, metadata: metadata, encryptionContext: context)
            }
            openedServerURLString = serverURLString
            try await pullAndReload(budgetID: metadata.groupID ?? metadata.cloudFileID, serverURLString: serverURLString)
            return
        }

        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }

        let client = connectionTransportFactory(baseURL)
        let fallbackRemote = ActualSyncRemoteFile(
            fileID: fileID,
            groupID: budget.groupId,
            name: budget.name,
            deleted: false,
            encryptKeyID: nil,
            requiresEncryptionPassword: false
        )
        let cachedRemote = remoteFilesByFileID[fileID]
        let fileInfo = try? await client.userFileInfo(fileID: fileID, token: token)
        let remote = fileInfo ?? cachedRemote ?? fallbackRemote
        let encryptionContext = try await encryptionContext(
            remote: remote,
            client: client,
            token: token,
            password: encryptionPassword
        )

        let stagedArchiveURL = try fileManager.prepareDownloadStaging(fileID: fileID)
        defer { fileManager.cleanupDownloadStaging(at: stagedArchiveURL) }
        try await client.downloadUserFile(fileID: fileID, token: token, to: stagedArchiveURL)
        try fileManager.validateStagedDownload(at: stagedArchiveURL)
        if let encryptMeta = remote.encryptMeta {
            guard let encryptionContext else {
                throw LocalFirstError.encryptedBudgetRequiresPassword
            }
            let encryptedData = try Data(contentsOf: stagedArchiveURL, options: .mappedIfSafe)
            let budgetData = try ActualBudgetCrypto.decrypt(
                encryptMeta.encryptedData(encryptedData),
                keyData: encryptionContext.keyData
            )
            try fileManager.replaceStagedDownload(at: stagedArchiveURL, with: budgetData)
        }
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: budget.groupId,
            budgetName: budget.name,
            encryptionKeyID: remote.syncEncryptionKeyID,
            nodeID: HybridLogicalClock.makeClientID()
        )
        _ = try fileManager.importBudgetZip(
            at: stagedArchiveURL,
            remoteFile: remote,
            metadata: metadata
        )
        try await openImportedBudget(fileID: fileID, metadata: metadata, encryptionContext: encryptionContext)
        openedServerURLString = serverURLString
        try await pullAndReload(budgetID: metadata.groupID ?? metadata.cloudFileID, serverURLString: serverURLString)
    }

    func openCachedBudget(_ budget: ActualBudget) async throws -> Bool {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }
        guard fileManager.importedDatabaseExists(fileID: fileID),
              let metadata = try fileManager.loadMetadata(fileID: fileID) else {
            return false
        }

        try await openImportedBudget(fileID: fileID, metadata: metadata)
        return true
    }

    /// Verifies the selected cached budget independently of the store's live database state.
    /// Connection editing uses this before replacing the persisted token or settings.
    func validateCachedBudgetCanOpen(_ budget: ActualBudget) async throws {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }
        guard fileManager.importedDatabaseExists(fileID: fileID),
              let metadata = try fileManager.loadMetadata(fileID: fileID) else {
            throw LocalFirstError.missingImportedDatabase
        }

        try fileManager.hardenCachedBudget(fileID: fileID)
        _ = try encryptionContext(metadata: metadata)
        let validationDatabase = try BudgetDatabase(
            databaseURL: fileManager.databaseURL(fileID: fileID),
            localNodeID: metadata.nodeID
        )
        try fileManager.hardenCachedBudget(fileID: fileID)
        _ = try await validationDatabase.fetchAccountDisplays()
    }

    /// Lean refresh for an already-open budget: pull CRDT messages and reload native caches.
    /// Does not re-list remote files or reopen the database.
    func refresh(budgetID: String, serverURLString: String) async throws {
        _ = try requireDatabase(for: budgetID)
        openedServerURLString = serverURLString
        try await pullAndReload(budgetID: budgetID, serverURLString: serverURLString)
    }

    /// Discard the locally imported SQLite database and re-download a fresh copy from the
    /// server. Used by Settings to recover from a stale or corrupted local budget.
    func reimportBudget(_ budget: ActualBudget, serverURLString: String) async throws {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }
        guard let originalMetadata = try fileManager.loadMetadata(fileID: fileID),
              fileManager.importedDatabaseExists(fileID: fileID) else {
            throw LocalFirstError.missingImportedDatabase
        }
        let token = keychain.readActualSyncToken()
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }
        guard let baseURL = URL(string: ActualServerURLNormalizer.normalize(serverURLString)) else {
            throw ActualAPIError.invalidURL
        }

        let client = connectionTransportFactory(baseURL)
        let fallbackRemote = ActualSyncRemoteFile(
            fileID: fileID,
            groupID: budget.groupId,
            name: budget.name
        )
        let remote = try await client.userFileInfo(fileID: fileID, token: token)
            ?? remoteFilesByFileID[fileID]
            ?? fallbackRemote
        let encryptionContext = try await encryptionContext(
            remote: remote,
            client: client,
            token: token,
            password: nil
        )

        let workspace = try fileManager.prepareReimportWorkspace(fileID: fileID)
        defer { fileManager.cleanupReimportWorkspace(workspace) }
        try await client.downloadUserFile(fileID: fileID, token: token, to: workspace.archiveURL)
        try fileManager.reimportCheckpoint(.afterDownload)
        try fileManager.validateStagedDownload(at: workspace.archiveURL)
        try fileManager.reimportCheckpoint(.beforeDecrypt)
        if let encryptMeta = remote.encryptMeta {
            guard let encryptionContext else {
                throw LocalFirstError.encryptedBudgetRequiresPassword
            }
            let encryptedData = try Data(contentsOf: workspace.archiveURL, options: .mappedIfSafe)
            let budgetData = try ActualBudgetCrypto.decrypt(
                encryptMeta.encryptedData(encryptedData),
                keyData: encryptionContext.keyData
            )
            try fileManager.replaceStagedDownload(at: workspace.archiveURL, with: budgetData)
        }

        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: remote.groupID ?? budget.groupId,
            budgetName: remote.name,
            encryptionKeyID: remote.syncEncryptionKeyID,
            nodeID: originalMetadata.nodeID
        )
        _ = try fileManager.importBudgetZip(
            at: workspace.archiveURL,
            into: workspace,
            metadata: metadata
        )
        let validationDatabase = try BudgetDatabase(
            databaseURL: workspace.databaseURL,
            localNodeID: metadata.nodeID
        )
        try await validationDatabase.validateImportedBudget()

        reset()
        var didSwap = false
        do {
            try fileManager.commitReimport(workspace, fileID: fileID)
            didSwap = true
            try await openImportedBudget(
                fileID: fileID,
                metadata: metadata,
                encryptionContext: encryptionContext
            )
            openedServerURLString = serverURLString
            try await pullAndReload(
                budgetID: metadata.groupID ?? metadata.cloudFileID,
                serverURLString: serverURLString
            )
        } catch {
            reset()
            if didSwap {
                try? fileManager.rollbackReimport(fileID: fileID)
            }
            if fileManager.importedDatabaseExists(fileID: fileID) {
                try? await openImportedBudget(fileID: fileID, metadata: originalMetadata)
                openedServerURLString = serverURLString
            }
            throw error
        }
    }

    func openBudgetForBackgroundDiffIfNeeded(
        _ budget: ActualBudget,
        serverURLString: String
    ) async throws -> Bool {
        if isOpen(budgetID: budget.syncID) {
            return true
        }
        if openedBudgetID != nil {
            reset()
        }
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }
        if fileManager.importedDatabaseExists(fileID: fileID),
           let metadata = try fileManager.loadMetadata(fileID: fileID) {
            try await openImportedBudget(fileID: fileID, metadata: metadata)
            return true
        }

        try await openBudget(budget, serverURLString: serverURLString)
        return false
    }

    func openImportedBudget(
        fileID: String,
        metadata: LocalFirstBudgetMetadata,
        encryptionContext providedEncryptionContext: ActualBudgetEncryptionContext? = nil
    ) async throws {
        try fileManager.hardenCachedBudget(fileID: fileID)
        let encryptionContext = try providedEncryptionContext ?? encryptionContext(metadata: metadata)
        let database = try BudgetDatabase(
            databaseURL: fileManager.databaseURL(fileID: fileID),
            localNodeID: metadata.nodeID
        )
        try fileManager.hardenCachedBudget(fileID: fileID)
        self.database = database
        openedBudgetID = metadata.groupID ?? metadata.cloudFileID
        openedGroupID = metadata.groupID
        openedNodeID = metadata.nodeID
        openedEncryptionContext = encryptionContext
        let budgetID = metadata.groupID ?? metadata.cloudFileID
        accountsByBudget[budgetID] = try? await database.fetchAccountDisplays()
        payeesByBudget[budgetID] = try? await database.fetchPayeeManagementSnapshot()
        let checkpoint = try? await database.localSyncCheckpoint()
        syncStatus = LocalFirstSyncStatus(
            fileID: budgetID,
            groupID: metadata.groupID,
            lastSyncedAt: checkpoint?.lastSyncedAt,
            lastAppliedMessageCount: checkpoint?.lastAppliedMessageCount ?? 0,
            lastUploadedMessageCount: checkpoint?.lastUploadedMessageCount ?? 0,
            encryptionKeyID: encryptionContext?.keyID,
            pendingLocalMessageCount: (try? await database.pendingLocalSyncMessageCount()) ?? 0
        )
        await syncClient.configure(
            LocalFirstSyncConfiguration(
                fileID: metadata.cloudFileID,
                groupID: metadata.groupID,
                nodeID: metadata.nodeID,
                encryptionKeyID: encryptionContext?.keyID,
                encryptionContext: encryptionContext
            )
        )
    }

    func encryptionContext(metadata: LocalFirstBudgetMetadata) throws -> ActualBudgetEncryptionContext? {
        guard let keyID = metadata.encryptionKeyID else {
            return nil
        }
        guard let keyData = keychain.readLocalFirstEncryptionKey(
            fileID: metadata.cloudFileID,
            keyID: keyID
        ) else {
            throw LocalFirstError.encryptedBudgetRequiresPassword
        }
        return ActualBudgetEncryptionContext(keyID: keyID, keyData: keyData)
    }

    func encryptionContext(
        metadata: LocalFirstBudgetMetadata,
        client: any ActualServerConnectionTransport,
        token: String,
        password: String
    ) async throws -> ActualBudgetEncryptionContext {
        guard let keyID = metadata.encryptionKeyID else {
            throw LocalFirstError.invalidEncryptionKey
        }
        let keyResponse = try await client.userKey(fileID: metadata.cloudFileID, token: token)
        let context = try ActualBudgetCrypto.validateUserKeyResponse(
            keyResponse,
            password: password
        )
        guard context.keyID == keyID else {
            throw LocalFirstError.invalidEncryptionKey
        }
        try keychain.saveLocalFirstEncryptionKey(
            context.keyData,
            fileID: metadata.cloudFileID,
            keyID: keyID
        )
        return context
    }

    func encryptionContext(
        remote: ActualSyncRemoteFile,
        client: any ActualServerConnectionTransport,
        token: String,
        password: String?
    ) async throws -> ActualBudgetEncryptionContext? {
        guard remote.requiresEncryptionPassword else {
            return nil
        }
        guard let keyID = remote.syncEncryptionKeyID else {
            throw LocalFirstError.invalidEncryptionKey
        }
        if let keyData = keychain.readLocalFirstEncryptionKey(fileID: remote.fileID, keyID: keyID) {
            return ActualBudgetEncryptionContext(keyID: keyID, keyData: keyData)
        }
        guard let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalFirstError.encryptedBudgetRequiresPassword
        }

        let keyResponse = try await client.userKey(fileID: remote.fileID, token: token)
        let context = try ActualBudgetCrypto.validateUserKeyResponse(
            keyResponse,
            password: password
        )
        guard context.keyID == keyID else {
            throw LocalFirstError.invalidEncryptionKey
        }
        try keychain.saveLocalFirstEncryptionKey(context.keyData, fileID: remote.fileID, keyID: keyID)
        return context
    }

}
