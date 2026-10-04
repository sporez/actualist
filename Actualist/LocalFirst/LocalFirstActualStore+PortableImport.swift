import Foundation

extension LocalFirstActualStore {
    /// Imports a user-chosen portable ZIP as a new budget: `PortableBudgetArchive`
    /// validates the archive and stages the sanitized `db.sqlite` +
    /// `metadata.json` pair, BudgetFileManager's new-directory install places
    /// that pair into a fresh local directory, and the existing
    /// `registerPortableBudget` client registers the archive on the Actual
    /// server — all under one file ID minted exactly once. The download
    /// installer (`importBudgetZip`) and `reimportBudget` are never used.
    ///
    /// The new budget exists locally and becomes selectable only after
    /// registration is confirmed. Like `createNewBudget`, an unconfirmed
    /// upload never keeps a local-only budget: any failure after the install
    /// deletes the new local directory and leaves nothing selectable, while
    /// the registered file remains on the server and is recoverable through
    /// the normal download path. A budget directory that already exists for
    /// the minted file ID is refused and never deleted.
    func importPortableBudget(
        archiveAt archiveURL: URL,
        serverURLString: String,
        encryptionPassword: String? = nil
    ) async throws -> NewBudgetCreation {
        let token = try keychain.readActualSyncToken()
        guard let token else {
            throw LocalFirstError.missingSyncToken
        }
        return try await importPortableBudget(
            archiveAt: archiveURL,
            serverURLString: serverURLString,
            encryptionPassword: encryptionPassword,
            token: token
        )
    }

    /// Test seam: explicit token, transport, recovery paths, and a
    /// deterministic identity generator. Production callers use the overload
    /// above.
    func importPortableBudget(
        archiveAt archiveURL: URL,
        serverURLString: String,
        encryptionPassword: String? = nil,
        token: String,
        registrationTransport: (any ActualFileRegistrationTransport)? = nil,
        listUserFiles: (@Sendable (String) async throws -> [ActualSyncRemoteFile])? = nil,
        userInfo: (@Sendable (String, String) async throws -> ActualSyncRemoteFile?)? = nil,
        identityGenerator: (@Sendable () -> String)? = nil
    ) async throws -> NewBudgetCreation {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appending(path: "portable-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let generateIdentity = identityGenerator ?? { UUID().uuidString }
        // The file ID is minted exactly once and is the only identity this
        // budget ever has, locally and on the server.
        let fileID = generateIdentity()
        let directory = try fileManager.budgetDirectory(fileID: fileID)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            // Thrown before any cleanup seam exists: an existing budget
            // directory is never deleted by an import attempt.
            throw NewBudgetError.budgetDirectoryAlreadyExists
        }

        // Validation stages the pair outside the budgets root; nothing local
        // is touched until the archive is accepted. The registration upload
        // carries the sanitized re-zip of the validated pair — never the raw
        // user zip, whose embedded metadata and unvalidated extra entries
        // must not reach the server.
        let validated: PortableBudgetArchive.ValidatedArchive
        let archiveBytes: Data
        do {
            let scoped = archiveURL.startAccessingSecurityScopedResource()
            defer { if scoped { archiveURL.stopAccessingSecurityScopedResource() } }
            let archive = PortableBudgetArchive()
            validated = try archive.validate(archiveAt: archiveURL, stagingDirectory: stagingRoot)
            archiveBytes = try archive.sanitizedArchiveBytes(
                databaseAt: validated.databaseURL,
                metadataAt: validated.metadataURL,
                stagingDirectory: stagingRoot
            )
        }

        let nodeID = HybridLogicalClock.makeClientID()
        var savedKeyID: String?
        do {
            try fileManager.installValidatedPortableBudget(
                databaseAt: validated.databaseURL,
                metadataAt: validated.metadataURL,
                fileID: fileID
            )
            // Before registration the local metadata carries only the safe
            // identity: the fresh file ID, the imported name, and this
            // device's node ID. The staged portable metadata.json cannot be
            // read as local budget metadata; the confirmed write below
            // replaces it with the receipt's group and key identities.
            try writeNewBudgetMetadata(
                fileID: fileID,
                budgetName: validated.metadata.budgetName,
                nodeID: nodeID,
                groupID: nil,
                encryptionKeyID: nil
            )
            try fileManager.hardenCachedBudget(fileID: fileID)

            let receipt = try await registerPortableBudget(
                archiveBytes: archiveBytes,
                budgetName: validated.metadata.budgetName,
                knownFileID: fileID,
                serverURLString: serverURLString,
                encryptionPassword: encryptionPassword,
                token: token,
                registrationTransport: registrationTransport,
                listUserFiles: listUserFiles,
                userInfo: userInfo
            )
            savedKeyID = receipt.encryptionKeyID
            try writeNewBudgetMetadata(
                fileID: fileID,
                budgetName: validated.metadata.budgetName,
                nodeID: nodeID,
                groupID: receipt.groupID,
                encryptionKeyID: receipt.encryptionKeyID
            )
            try fileManager.hardenCachedBudget(fileID: fileID)
            return NewBudgetCreation(
                fileID: receipt.fileID,
                groupID: receipt.groupID,
                budgetName: validated.metadata.budgetName,
                encryptionKeyID: receipt.encryptionKeyID
            )
        } catch {
            // No selectable budget may survive a failed or unconfirmed import.
            try? fileManager.deleteImportedBudget(fileID: fileID)
            discardSavedEncryptionKey(fileID: fileID, keyID: savedKeyID)
            throw error
        }
    }
}
