import Foundation

struct StagedLocalFirstConnection {
    let token: String
    let budgets: [ActualBudget]
    let remoteFilesByFileID: [String: ActualSyncRemoteFile]
}

extension LocalFirstActualStore {
    func loginMethods(serverURLString: String) async throws -> ActualLoginMethodsResponse {
        try await withConnectionFailover(serverURLString: serverURLString) { client in
            try await client.loginMethods()
        }
    }

    func stageConnection(
        serverURLString: String,
        password: String,
        selectedBudgetID: String?
    ) async throws -> StagedLocalFirstConnection {
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalFirstError.missingPassword
        }

        return try await withConnectionFailover(serverURLString: serverURLString) { client in
            _ = try await client.loginMethods()
            let response = try await client.loginWithPassword(password: password)
            return try await self.stageAuthenticatedConnection(
                client: client,
                token: response.token,
                selectedBudgetID: selectedBudgetID
            )
        }
    }

    func stageOpenIDConnection(
        serverURLString: String,
        selectedBudgetID: String?,
        browserSession: @escaping ActualOpenIDBrowserSession
    ) async throws -> StagedLocalFirstConnection {
        return try await withConnectionFailover(serverURLString: serverURLString) { client in
            let methods = try await client.loginMethods()
            guard methods.availableLoginMethods.contains(where: { $0.authenticationMethod == .openID }) else {
                throw ActualAPIError.unsupportedAuthenticationMethod("openid")
            }

            let token = try await self.openIDAuthenticationCoordinator.authenticate(
                client: client,
                browserSession: browserSession
            )
            return try await self.stageAuthenticatedConnection(
                client: client,
                token: token,
                selectedBudgetID: selectedBudgetID
            )
        }
    }

    func stageAuthenticatedConnection(
        serverURLString: String,
        token: String,
        selectedBudgetID: String?
    ) async throws -> StagedLocalFirstConnection {
        return try await withConnectionFailover(serverURLString: serverURLString) { client in
            try await self.stageAuthenticatedConnection(
                client: client,
                token: token,
                selectedBudgetID: selectedBudgetID
            )
        }
    }

    private func stageAuthenticatedConnection(
        client: any ActualServerConnectionTransport,
        token: String,
        selectedBudgetID: String?
    ) async throws -> StagedLocalFirstConnection {
        guard !token.isEmpty else {
            throw LocalFirstError.missingSyncToken
        }

        let files = try await client.listUserFiles(token: token)
        guard !files.isEmpty else {
            throw LocalFirstError.noBudgetsAvailable
        }

        let budgets = files.map(\.actualBudget)
        if let selectedBudgetID,
           !budgets.contains(where: { $0.syncID == selectedBudgetID }) {
            throw LocalFirstError.selectedBudgetUnavailable
        }

        return StagedLocalFirstConnection(
            token: token,
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

        let files = try await withConnectionFailover(serverURLString: serverURLString) { client in
            try await client.listUserFiles(token: token)
        }
        remoteFilesByFileID = files.reduce(into: [:]) { cache, file in
            cache[file.fileID] = file
        }
        cachedBudgets = files.map(\.actualBudget)
        return cachedBudgets
    }

    func requiresEncryptionPasswordToOpen(_ budget: ActualBudget) -> Bool {
        guard let fileID = budget.localFirstFileID else {
            return false
        }
        if openedBudgetID == budget.syncID, openedEncryptionContext != nil {
            return false
        }

        let remoteKeyID = remoteFilesByFileID[fileID].flatMap { remote in
            remote.requiresEncryptionPassword ? remote.syncEncryptionKeyID : nil
        }
        let importedKeyID = (try? fileManager.loadMetadata(fileID: fileID))?.encryptionKeyID
        guard let keyID = remoteKeyID ?? importedKeyID else {
            return false
        }
        return keychain.readLocalFirstEncryptionKey(fileID: fileID, keyID: keyID) == nil
    }

    func openBudget(
        _ budget: ActualBudget,
        serverURLString: String,
        encryptionPassword: String? = nil
    ) async throws {
        guard let fileID = budget.localFirstFileID else {
            throw LocalFirstError.missingBudgetFileID
        }

        // Reopening would discard the current database actor and caches.
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
                let context = try await withConnectionFailover(
                    serverURLString: serverURLString
                ) { client in
                    try await self.encryptionContext(
                        metadata: metadata,
                        client: client,
                        token: token,
                        password: encryptionPassword
                    )
                }
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

        let fallbackRemote = ActualSyncRemoteFile(
            fileID: fileID,
            groupID: budget.groupId,
            name: budget.name,
            deleted: false,
            encryptKeyID: nil,
            requiresEncryptionPassword: false
        )
        let cachedRemote = remoteFilesByFileID[fileID]
        let stagedArchiveURL = try fileManager.prepareDownloadStaging(fileID: fileID)
        defer { fileManager.cleanupDownloadStaging(at: stagedArchiveURL) }
        let (remote, encryptionContext) = try await withConnectionFailover(
            serverURLString: serverURLString
        ) { client in
            let fileInfo: ActualSyncRemoteFile?
            do {
                fileInfo = try await client.userFileInfo(fileID: fileID, token: token)
            } catch {
                // Transport / gateway / local-network errors propagate so the
                // failover wrapper retries them against the fallback. Other
                // server/app errors stay tolerated as "file info unavailable".
                if LocalFirstActualStore.isFailoverEligible(error) { throw error }
                fileInfo = nil
            }
            let remote = fileInfo ?? cachedRemote ?? fallbackRemote
            let encryptionContext = try await self.encryptionContext(
                remote: remote,
                client: client,
                token: token,
                password: encryptionPassword
            )
            try await client.downloadUserFile(fileID: fileID, token: token, to: stagedArchiveURL)
            return (remote, encryptionContext)
        }
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

    func refresh(budgetID: String, serverURLString: String) async throws {
        _ = try requireDatabase(for: budgetID)
        openedServerURLString = serverURLString
        try await pullAndReload(budgetID: budgetID, serverURLString: serverURLString)
    }

    func reimportBudget(_ budget: ActualBudget, serverURLString: String) async throws {
        if isDemoBudgetActive {
            // Demo mode is local-only; there is no server copy to re-download.
            return
        }
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

        let fallbackRemote = ActualSyncRemoteFile(
            fileID: fileID,
            groupID: budget.groupId,
            name: budget.name
        )
        let cachedRemote = remoteFilesByFileID[fileID]
        let workspace = try fileManager.prepareReimportWorkspace(fileID: fileID)
        defer { fileManager.cleanupReimportWorkspace(workspace) }
        let (remote, encryptionContext) = try await withConnectionFailover(
            serverURLString: serverURLString
        ) { client in
            let remote = try await client.userFileInfo(fileID: fileID, token: token)
                ?? cachedRemote
                ?? fallbackRemote
            let encryptionContext = try await self.encryptionContext(
                remote: remote,
                client: client,
                token: token,
                password: nil
            )
            try await client.downloadUserFile(fileID: fileID, token: token, to: workspace.archiveURL)
            return (remote, encryptionContext)
        }
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
        isDemoBudgetActive = (metadata.cloudFileID == DemoBudget.fileID)
        let budgetID = metadata.groupID ?? metadata.cloudFileID
        await reloadBudgetCurrency(database: database, budgetID: budgetID)
        try? await reloadAccountCaches(database: database, budgetID: budgetID)
        payeesByBudget[budgetID] = try? await database.fetchPayeeManagementSnapshot()
            .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
        await refreshActionLogDiagnosticSnapshot(database: database)
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

        // Seed the first Budget frame before foreground sync begins.
        _ = try? await currentBudgetMonth(
            budgetID: budgetID,
            preferredMonth: YearMonth(date: Date()).rawValue
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
