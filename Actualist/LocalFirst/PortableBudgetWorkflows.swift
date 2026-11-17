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
            "A budget with this identity already exists on this device. Try again."
        }
    }
}

/// Creating a budget from the starter seed, importing a portable ZIP,
/// registering either on the Actual server, and exporting the open budget as a
/// portable ZIP. The store owns it; none of these flows keeps state of its own.
@MainActor
final class PortableBudgetWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

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
        let token = try store.keychain.readActualSyncToken()
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
        let directory = try store.fileManager.budgetDirectory(fileID: fileID)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NewBudgetError.budgetDirectoryAlreadyExists
        }

        var savedKeyID: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try await NewBudgetSeedSQL.createNewBudgetStarterDatabase(
                at: store.fileManager.databaseURL(fileID: fileID),
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
            try store.fileManager.hardenCachedBudget(fileID: fileID)

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
            try store.fileManager.hardenCachedBudget(fileID: fileID)
            return NewBudgetCreation(
                fileID: receipt.fileID,
                groupID: receipt.groupID,
                budgetName: trimmedName,
                encryptionKeyID: receipt.encryptionKeyID
            )
        } catch {
            // No selectable budget may survive a failed or unconfirmed
            // creation.
            try? store.fileManager.discardUnfinishedBudget(fileID: fileID)
            discardSavedEncryptionKey(fileID: fileID, keyID: savedKeyID)
            throw error
        }
    }

    /// Shared by the New Budget create and portable import flows: a failed
    /// creation or import must not leave the unlocked key it just saved.
    private func discardSavedEncryptionKey(fileID: String, keyID: String?) {
        guard let keyID else { return }
        try? store.keychain.removeLocalFirstEncryptionKey(fileID: fileID, keyID: keyID)
    }

    /// Shared by the New Budget create and portable import flows: the local
    /// metadata write behind a freshly registered budget directory.
    private func writeNewBudgetMetadata(
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
            to: store.fileManager.metadataURL(fileID: fileID),
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
        let token = try store.keychain.readActualSyncToken()
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
        let directory = try store.fileManager.budgetDirectory(fileID: fileID)
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
        let (validated, archiveBytes) = try await PortableBudgetWorkflows.validatePortableArchive(
            at: archiveURL,
            stagingRoot: stagingRoot
        )

        let nodeID = HybridLogicalClock.makeClientID()
        var savedKeyID: String?
        do {
            try store.fileManager.installValidatedPortableBudget(
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
            try store.fileManager.hardenCachedBudget(fileID: fileID)

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
            try store.fileManager.hardenCachedBudget(fileID: fileID)
            return NewBudgetCreation(
                fileID: receipt.fileID,
                groupID: receipt.groupID,
                budgetName: validated.metadata.budgetName,
                encryptionKeyID: receipt.encryptionKeyID
            )
        } catch {
            // No selectable budget may survive a failed or unconfirmed import.
            try? store.fileManager.discardUnfinishedBudget(fileID: fileID)
            discardSavedEncryptionKey(fileID: fileID, keyID: savedKeyID)
            throw error
        }
    }

    /// Extraction, sanitizing, validation and the sanitized re-zip are blocking
    /// file and SQLite work, so they run off the main actor. Nothing local is
    /// touched here; the staged pair lives under `stagingRoot`.
    @concurrent
    private static func validatePortableArchive(
        at archiveURL: URL,
        stagingRoot: URL
    ) async throws -> (PortableBudgetArchive.ValidatedArchive, Data) {
        let scoped = archiveURL.startAccessingSecurityScopedResource()
        defer { if scoped { archiveURL.stopAccessingSecurityScopedResource() } }
        let archive = PortableBudgetArchive()
        let validated = try archive.validate(archiveAt: archiveURL, stagingDirectory: stagingRoot)
        // The new server group starts empty, so the carried CRDT history
        // is cleared before the upload and the install (upstream
        // `resetSync`). Never applied to downloads or reimports.
        do {
            try PortableDatabaseSQL.resetSyncHistory(atStagedPortableDatabase: validated.databaseURL)
        } catch {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .integrity)
        }
        let archiveBytes = try archive.sanitizedArchiveBytes(
            databaseAt: validated.databaseURL,
            metadataAt: validated.metadataURL,
            stagingDirectory: stagingRoot
        )
        return (validated, archiveBytes)
    }

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
        let token = try store.keychain.readActualSyncToken()
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
                try await store.withConnectionFailover(serverURLString: serverURLString) { client in
                    try await client.listUserFiles(token: token)
                }
            }
        }
        if let userInfo {
            recoveryInfo = userInfo
        } else {
            recoveryInfo = { [self] fileID, token in
                try await store.withConnectionFailover(serverURLString: serverURLString) { client in
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
            do {
                try store.keychain.saveLocalFirstEncryptionKey(
                    keySet.keyData,
                    fileID: knownFileID,
                    keyID: keySet.keyID
                )
            } catch {
                // Without the saved key the registered file cannot be opened
                // here; withdraw it, best effort.
                await flow.abandonLandedFile(knownFileID, token: token)
                throw error
            }
        }
        return receipt
    }

    private func makeRegistrationTransport(
        serverURLString: String
    ) throws -> any ActualFileRegistrationTransport {
        guard let serverURL = store.failoverEndpoints(for: serverURLString).primary else {
            throw ActualAPIError.invalidURL
        }
        let fields = try store.keychain.readCustomHTTPHeaders().fields(for: .primary, url: serverURL)
        return ActualServerFileRegistrationClient(
            baseURL: serverURL,
            customHeaders: fields,
            session: store.transportSession
        )
    }

    /// Exports the currently open budget as a portable ZIP through the
    /// existing `PortableBudgetArchive` export: a consistent snapshot of the
    /// open database (never a live `db.sqlite` copy) plus allowlisted
    /// metadata, written to a fresh file in `PortableExportFiles` that the caller shares
    /// and later discards. Nothing
    /// is uploaded, the server is never contacted, and the open budget's
    /// local files are unchanged.
    ///
    /// Refuses when `budgetID` is not the open budget. If the budget switches
    /// while the snapshot is being written, the finished archive is deleted
    /// and the export reports cancellation, mirroring the CSV export's
    /// stale-result handling.
    func exportPortableBudgetArchive(budgetID: String) async throws -> URL {
        let database = try store.requireDatabase(for: budgetID)
        // The open budget's local files are keyed by its cloud file ID, which
        // differs from `budgetID` (the group-based open-budget identity)
        // whenever the budget belongs to a group. The sync session retains
        // that file ID for the open budget; a stale or closed session leaves
        // it unset, and the post-export open-budget guard discards the result.
        guard let fileID = await store.syncClient.configuration?.fileID else {
            throw LocalFirstError.budgetNotOpened
        }
        // The local metadata is the source of truth for the open budget's
        // name; the cached server list only covers a metadata read failure.
        let metadata = try? store.fileManager.loadMetadata(fileID: fileID)
        let budgetName = metadata?.budgetName
            ?? store.cachedBudgets.first(where: { $0.syncID == budgetID })?.name
            ?? ""
        let exportFiles = store.portableExportFiles
        exportFiles.sweepStale()
        let archiveURL = try exportFiles.makeArchiveURL()
        do {
            try await PortableBudgetWorkflows.writePortableArchive(
                database: database,
                budgetName: budgetName,
                sourceIdentity: budgetID,
                to: archiveURL
            )
            try exportFiles.protect(archiveURL)
        } catch {
            exportFiles.discard(archiveURL)
            throw error
        }
        guard store.database === database, store.openedBudgetID == budgetID else {
            exportFiles.discard(archiveURL)
            throw CancellationError()
        }
        return archiveURL
    }

    /// Zipping the snapshot is blocking file work. Off the main actor, the UI
    /// keeps drawing (the Export row's spinner) while the share sheet waits.
    @concurrent
    private static func writePortableArchive(
        database: BudgetDatabase,
        budgetName: String,
        sourceIdentity: String,
        to archiveURL: URL
    ) async throws {
        _ = try await PortableBudgetArchive().export(
            database: database,
            budgetName: budgetName,
            sourceIdentity: sourceIdentity,
            to: archiveURL
        )
    }
}
