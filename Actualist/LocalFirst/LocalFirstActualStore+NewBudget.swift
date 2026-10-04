import Foundation

/// What a completed New Budget creation records. The identity is complete only
/// after registration was confirmed on the server; callers hand it to the
/// existing budget-selection handoff (`selectBudgetForCurrentBackend` /
/// `AppSessionRecovery`) — never to a picker flag or continuation on
/// `AppState`.
struct NewBudgetCreation: Equatable, Sendable {
    let fileID: String
    let groupID: String?
    let budgetName: String
    let encryptionKeyID: String?
}

enum NewBudgetError: LocalizedError, Equatable {
    case invalidBudgetName
    /// A fresh file ID collides with an existing local budget directory.
    /// Creation refuses instead of touching the existing budget's files.
    case budgetDirectoryAlreadyExists

    var errorDescription: String? {
        switch self {
        case .invalidBudgetName:
            "Enter a name for the new budget."
        case .budgetDirectoryAlreadyExists:
            "A local budget already uses this new budget's identity."
        }
    }
}

extension LocalFirstActualStore {
    /// Creates a brand-new starter budget: projects the bundled starter seed
    /// into a new local directory, builds a portable archive from that seed
    /// through the existing `PortableBudgetArchive` export, and registers the
    /// archive as a new file on the Actual server through the existing
    /// `registerPortableBudget` client — the same single upload path imports
    /// use, with no second upload path.
    ///
    /// The new budget exists locally and becomes selectable only after
    /// registration is confirmed. Unlike Actual's `createBudget`, an upload
    /// failure never keeps a local-only budget: any failure deletes the new
    /// local directory and leaves nothing selectable. A confirmed registration
    /// whose final local metadata write still fails also cleans up; the
    /// registered file remains on the server and is recoverable through the
    /// normal download path.
    ///
    /// The currently open budget — including the demo budget — is never
    /// cleared or cloned: the archive is exported from the new seed database,
    /// not from the open one.
    func createNewBudget(
        named budgetName: String,
        serverURLString: String,
        encryptionPassword: String? = nil
    ) async throws -> NewBudgetCreation {
        let token = try keychain.readActualSyncToken()
        guard let token else {
            throw LocalFirstError.missingSyncToken
        }
        return try await createNewBudget(
            named: budgetName,
            serverURLString: serverURLString,
            encryptionPassword: encryptionPassword,
            token: token
        )
    }

    /// Test seam: explicit token, transport, recovery paths, and a
    /// deterministic identity generator. Production callers use the overload
    /// above.
    func createNewBudget(
        named budgetName: String,
        serverURLString: String,
        encryptionPassword: String? = nil,
        token: String,
        registrationTransport: (any ActualFileRegistrationTransport)? = nil,
        listUserFiles: (@Sendable (String) async throws -> [ActualSyncRemoteFile])? = nil,
        userInfo: (@Sendable (String, String) async throws -> ActualSyncRemoteFile?)? = nil,
        identityGenerator: (@Sendable () -> String)? = nil
    ) async throws -> NewBudgetCreation {
        let trimmedName = budgetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedName.contains("\0") else {
            throw NewBudgetError.invalidBudgetName
        }
        try ActualBudgetFileRegistrationInput.validateName(trimmedName)
        let generateIdentity = identityGenerator ?? { UUID().uuidString }
        // The file ID is minted exactly once and is the only identity this
        // budget ever has, locally and on the server.
        let fileID = generateIdentity()
        let nodeID = HybridLogicalClock.makeClientID()
        let directory = try fileManager.budgetDirectory(fileID: fileID)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NewBudgetError.budgetDirectoryAlreadyExists
        }

        var savedKeyID: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try BudgetDatabase.makeNewBudgetStarterDatabase(
                at: fileManager.databaseURL(fileID: fileID),
                identityGenerator: generateIdentity
            )
            // Before registration the local metadata carries only the safe
            // identity: the fresh file ID, the name, and this device's node
            // ID. Group and key identities arrive only with the confirmed
            // registration receipt.
            try writeNewBudgetMetadata(
                fileID: fileID,
                budgetName: trimmedName,
                nodeID: nodeID,
                groupID: nil,
                encryptionKeyID: nil
            )
            try fileManager.hardenCachedBudget(fileID: fileID)

            let archiveBytes = try await exportNewBudgetArchive(
                database: database,
                budgetName: trimmedName,
                sourceIdentity: fileID
            )
            let receipt = try await registerPortableBudget(
                archiveBytes: archiveBytes,
                budgetName: trimmedName,
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
                budgetName: trimmedName,
                nodeID: nodeID,
                groupID: receipt.groupID,
                encryptionKeyID: receipt.encryptionKeyID
            )
            try fileManager.hardenCachedBudget(fileID: fileID)
            return NewBudgetCreation(
                fileID: receipt.fileID,
                groupID: receipt.groupID,
                budgetName: trimmedName,
                encryptionKeyID: receipt.encryptionKeyID
            )
        } catch {
            // No selectable budget may survive a failed or unconfirmed
            // creation.
            try? fileManager.discardUnfinishedBudget(fileID: fileID)
            discardSavedEncryptionKey(fileID: fileID, keyID: savedKeyID)
            throw error
        }
    }

    /// Shared by the New Budget create and portable import flows: a failed
    /// creation or import must not leave the unlocked key it just saved.
    func discardSavedEncryptionKey(fileID: String, keyID: String?) {
        guard let keyID else { return }
        try? keychain.removeLocalFirstEncryptionKey(fileID: fileID, keyID: keyID)
    }

    /// Shared by the New Budget create and portable import flows: the local
    /// metadata write behind a freshly registered budget directory.
    func writeNewBudgetMetadata(
        fileID: String,
        budgetName: String,
        nodeID: String,
        groupID: String?,
        encryptionKeyID: String?
    ) throws {
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: groupID,
            budgetName: budgetName,
            encryptionKeyID: encryptionKeyID,
            nodeID: nodeID
        )
        try JSONEncoder.actual.encode(metadata).write(
            to: fileManager.metadataURL(fileID: fileID),
            options: .atomic
        )
    }

    private func exportNewBudgetArchive(
        database: BudgetDatabase,
        budgetName: String,
        sourceIdentity: String
    ) async throws -> Data {
        let archiveURL = FileManager.default.temporaryDirectory
            .appending(path: "new-budget-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let archive = PortableBudgetArchive()
        _ = try await archive.export(
            database: database,
            budgetName: budgetName,
            sourceIdentity: sourceIdentity,
            to: archiveURL
        )
        return try Data(contentsOf: archiveURL)
    }
}
