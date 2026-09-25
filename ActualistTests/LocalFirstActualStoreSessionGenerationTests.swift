import Foundation
import Security
import SwiftProtobuf
import Testing
@testable import Actualist

private actor GatedSessionSyncTransport: ActualSyncTransport {
    let gate: StubConnectionWaitGate
    let response: Data
    private(set) var uploadedCount = 0

    init(gate: StubConnectionWaitGate, response: Data = Data()) {
        self.gate = gate
        self.response = response
    }

    func sync(data: Data, token: String) async throws -> Data {
        let request = try ActualSync_SyncRequest(serializedBytes: data)
        uploadedCount = request.messages.count
        await gate.wait()
        if response.isEmpty { return try ActualSync_SyncResponse().serializedData() }
        return response
    }
}

extension LocalFirstActualStoreTests {
    @Test func staleRemoteSyncCannotApplyOrPublishAfterSameBudgetReopen() async throws {
        let gate = StubConnectionWaitGate()
        var response = ActualSync_SyncResponse()
        response.messages = [try LocalFirstSyncMessageBuilder.envelope(
            for: remoteMessage(index: 1, row: "txn", column: "amount", value: .int(-7_777))
        )]
        let transport = GatedSessionSyncTransport(gate: gate, response: try response.serializedData())
        let bundle = try await makeOpenedWritableStoreBundle(syncTransportFactory: { _ in transport })
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let pending = Task {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://synthetic.invalid")
        }
        await gate.waitForEntry()
        #expect(await gate.didEnter)
        bundle.store.closeOpenBudget()
        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        bundle.store.syncStatus?.lastError = "new-session-status"
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(bundle.store.syncStatus?.lastError == "new-session-status")
        let currentDatabase = try #require(bundle.store.database)
        let transaction = try #require(try await currentDatabase.fetchTransaction(id: "txn"))
        #expect(transaction.amount == -12_345)
    }

    @Test func confirmedUploadFromRetiredSessionLeavesPendingLocalMessagesForRetry() async throws {
        let gate = StubConnectionWaitGate()
        let transport = GatedSessionSyncTransport(gate: gate)
        let bundle = try await makeOpenedWritableStoreBundle(syncTransportFactory: { _ in transport })
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            expectedMode: nil, categoryID: "groceries", budgeted: 62_500,
            budgetID: "group-1", month: "2026-07"
        ) {}
        let initialCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        #expect(initialCount > 0)
        let pending = Task {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://synthetic.invalid")
        }
        await gate.waitForEntry()
        #expect(await gate.didEnter)
        bundle.store.closeOpenBudget()
        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await transport.uploadedCount == initialCount)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == initialCount)
        #expect(bundle.store.syncStatus?.lastSyncedAt == nil)
    }

    @Test func logoutDuringCancellationInsensitiveReimportDownloadCannotRecreateErasedBudget() async throws {
        let gate = StubConnectionWaitGate()
        let archive = try makeArchiveData(databaseURL: makeSQLiteFixture())
        let transport = StubConnectionTransport(files: [testRemoteFile()], downloadData: archive, downloadGate: gate)
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            keychainBackend: backend, connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let state = try makeAppState(for: bundle)
        state.selectedBudget = bundle.budget
        state.setupPhase = .ready
        let pending = Task { await state.reimportLocalFirstBudget() }
        await gate.waitForEntry()
        #expect(await gate.didEnter)
        state.disconnectAndEraseLocalData()
        await gate.release()
        await pending.value
        #expect(state.setupPhase == .needsConnection)
        #expect(state.settings.selectedBudgetID == nil)
        #expect(!bundle.fileManager.importedDatabaseExists(fileID: "file-1"))
        #expect(!(try bundle.fileManager.reimportBackupExists(fileID: "file-1")))
        #expect(try bundle.keychain.readActualSyncToken() == nil)
        #expect(!bundle.store.hasOpenBudget)
    }

    @Test func logoutAfterReimportSwapDoesNotRollbackOrReopenErasedFiles() async throws {
        let archive = try makeArchiveData(databaseURL: makeSQLiteFixture())
        let transport = StubConnectionTransport(files: [testRemoteFile()], downloadData: archive)
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            keychainBackend: backend, connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let state = try makeAppState(for: bundle)
        state.selectedBudget = bundle.budget
        state.setupPhase = .ready
        var resumeOpen: CheckedContinuation<Void, Never>?
        let openPaused = TestLatch()
        bundle.store.budgetOpenSuspension = {
            await withCheckedContinuation { continuation in
                resumeOpen = continuation
                openPaused.trip()
            }
        }
        let pending = Task { await state.reimportLocalFirstBudget() }
        await openPaused.wait()
        let resume = try #require(resumeOpen)
        state.disconnectAndEraseLocalData()
        resume.resume()
        await pending.value
        #expect(state.setupPhase == .needsConnection)
        #expect(!bundle.fileManager.importedDatabaseExists(fileID: "file-1"))
        #expect(!(try bundle.fileManager.reimportBackupExists(fileID: "file-1")))
        #expect(!bundle.store.hasOpenBudget)
    }

    @Test func switchingBudgetDuringReimportKeepsReplacementSelectionAndCache() async throws {
        let gate = StubConnectionWaitGate()
        let archive = try makeArchiveData(databaseURL: makeSQLiteFixture())
        let transport = StubConnectionTransport(files: [testRemoteFile()], downloadData: archive, downloadGate: gate)
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            keychainBackend: backend, connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let otherFileID = "file-2"
        let otherDirectory = try bundle.fileManager.budgetDirectory(fileID: otherFileID)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: bundle.fileManager.databaseURL(fileID: "file-1"),
            to: bundle.fileManager.databaseURL(fileID: otherFileID)
        )
        try JSONEncoder.actual.encode(LocalFirstBudgetMetadata(
            localBudgetID: otherFileID, cloudFileID: otherFileID,
            groupID: "group-2", budgetName: "Replacement", encryptionKeyID: nil, nodeID: "node-2"
        )).write(to: bundle.fileManager.metadataURL(fileID: otherFileID))
        let state = try makeAppState(for: bundle)
        state.selectedBudget = bundle.budget
        state.setupPhase = .ready
        let pending = Task { await state.reimportLocalFirstBudget() }
        await gate.waitForEntry()
        #expect(await gate.didEnter)
        let replacement = ActualBudget(
            budgetID: otherFileID, cloudFileId: otherFileID,
            groupId: "group-2", name: "Replacement", state: nil
        )
        await state.selectBudgetForCurrentBackend(replacement)
        #expect(state.setupPhase == .ready)
        await gate.release()
        await pending.value
        #expect(state.settings.selectedBudgetID == "group-2")
        #expect(bundle.store.isOpen(budgetID: "group-2"))
        #expect(bundle.fileManager.importedDatabaseExists(fileID: otherFileID))
        #expect(!(try bundle.fileManager.reimportBackupExists(fileID: "file-1")))
    }

    @Test func serverChangeDuringReimportDownloadPreservesNewConnection() async throws {
        let gate = StubConnectionWaitGate()
        let archive = try makeArchiveData(databaseURL: makeSQLiteFixture())
        let transport = StubConnectionTransport(files: [testRemoteFile()], downloadData: archive, downloadGate: gate)
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            keychainBackend: backend, connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let state = try makeAppState(for: bundle)
        state.selectedBudget = bundle.budget
        state.setupPhase = .ready
        let pending = Task { await state.reimportLocalFirstBudget() }
        await gate.waitForEntry()
        #expect(await gate.didEnter)
        #expect(await state.saveLocalFirstConnection(
            serverURLString: "https://replacement.invalid", password: "synthetic-password"
        ))
        await gate.release()
        await pending.value
        #expect(state.settings.localFirstServerURLString == "https://replacement.invalid")
        #expect(state.setupPhase == .selectingBudget)
        #expect(state.settings.selectedBudgetID == nil)
        #expect(state.selectedBudget == nil)
        #expect(!bundle.store.hasOpenBudget)
        #expect(try bundle.keychain.readActualSyncToken() == "staged-token")
        #expect(bundle.fileManager.importedDatabaseExists(fileID: "file-1"))
        #expect(!(try bundle.fileManager.reimportBackupExists(fileID: "file-1")))
    }

    @Test func cancelledDiscoveryCannotFallbackToRecreatedRetiredCache() async throws {
        let gate = StubConnectionWaitGate()
        let transport = StubConnectionTransport(listUserFilesGate: gate)
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            keychainBackend: backend, connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let directory = try bundle.fileManager.budgetDirectory(fileID: "file-1")
        let database = try Data(contentsOf: bundle.fileManager.databaseURL(fileID: "file-1"))
        let metadata = try Data(contentsOf: bundle.fileManager.metadataURL(fileID: "file-1"))
        bundle.store.reset()
        try FileManager.default.removeItem(at: directory)
        let recovery = AppSessionRecovery()
        var settings = AppSettings(localFirstServerURLString: "https://synthetic.invalid")
        settings.selectedBudgetID = "group-1"
        settings.selectedLocalFirstFileID = "file-1"
        settings.selectedLocalFirstGroupID = "group-1"
        let pending = Task {
            await recovery.restoreForLaunch(
                settings: settings, keychain: bundle.keychain, store: bundle.store, isDemoMode: false
            )
        }
        await gate.waitForEntry()
        #expect(await gate.didEnter)
        recovery.invalidate()
        bundle.store.reset()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try database.write(to: bundle.fileManager.databaseURL(fileID: "file-1"))
        try metadata.write(to: bundle.fileManager.metadataURL(fileID: "file-1"))
        await gate.release()
        if case .superseded = await pending.value {} else { Issue.record("Stale restore reopened old cache") }
        #expect(!bundle.store.hasOpenBudget)
    }

    @Test func logoutWhileDiscoveryIgnoresCancellationCannotPublishBudgetList() async throws {
        let gate = StubConnectionWaitGate()
        let remote = ActualSyncRemoteFile(fileID: "remote", groupID: "remote-group", name: "Remote")
        let transport = StubConnectionTransport(files: [remote], listUserFilesGate: gate)
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            keychainBackend: backend, connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let state = try makeAppState(for: bundle)
        bundle.store.reset()
        let pending = Task { try await state.loadBudgets() }
        await gate.waitForEntry()
        #expect(await gate.didEnter)
        state.disconnectAndEraseLocalData()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(state.setupPhase == .needsConnection)
        #expect(state.budgets.isEmpty)
        #expect(bundle.store.cachedBudgets.isEmpty)
        #expect(!bundle.store.hasOpenBudget)
    }

    @Test func logoutDuringEncryptedKeyFetchNeverPersistsRetiredKeyOrBudget() async throws {
        let gate = StubConnectionWaitGate()
        let password = "synthetic-password"
        let salt = "synthetic-salt"
        let keyData = try ActualBudgetCrypto.deriveKey(password: password, salt: salt)
        let context = ActualBudgetEncryptionContext(keyID: "key-1", keyData: keyData)
        let encrypted = try ActualBudgetCrypto.encrypt(Data("synthetic".utf8), context: context)
        let testPayload = ActualUserKeyResponse.TestPayload(
            value: encrypted.data.base64EncodedString(),
            meta: ActualEncryptedMetadata(
                keyID: "key-1", algorithm: ActualBudgetCrypto.algorithm,
                iv: encrypted.iv.base64EncodedString(), authTag: encrypted.authTag.base64EncodedString()
            )
        )
        let response = ActualUserKeyResponse(
            id: "key-1", salt: salt,
            test: String(decoding: try JSONEncoder.actual.encode(testPayload), as: UTF8.self)
        )
        let transport = StubConnectionTransport(userKeyGate: gate, userKeyResponse: response)
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            keychainBackend: backend, connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let metadataURL = try bundle.fileManager.metadataURL(fileID: "file-1")
        let original = try JSONDecoder.actual.decode(LocalFirstBudgetMetadata.self, from: Data(contentsOf: metadataURL))
        try JSONEncoder.actual.encode(LocalFirstBudgetMetadata(
            localBudgetID: original.localBudgetID, cloudFileID: original.cloudFileID,
            groupID: original.groupID, budgetName: original.budgetName,
            encryptionKeyID: "key-1", nodeID: original.nodeID
        )).write(to: metadataURL)
        bundle.store.reset()
        let state = try makeAppState(for: bundle)
        let budget = ActualBudget(
            budgetID: "file-1", cloudFileId: "file-1", groupId: "group-1", name: "Budget", state: nil
        )
        let pending = Task { await state.selectBudgetForCurrentBackend(budget, encryptionPassword: password) }
        await gate.waitForEntry()
        #expect(await gate.didEnter)
        state.disconnectAndEraseLocalData()
        await gate.release()
        await pending.value
        #expect(state.setupPhase == .needsConnection)
        #expect(try bundle.keychain.readActualSyncToken() == nil)
        #expect(try bundle.keychain.readLocalFirstEncryptionKey(fileID: "file-1", keyID: "key-1") == nil)
        #expect(!bundle.store.hasOpenBudget)
    }

    @Test func logoutDuringLaunchWarmupCannotRepublishOldAccountsOrDiagnostics() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        var resumeWarmup: CheckedContinuation<Void, Never>?
        let warmupPaused = TestLatch()
        bundle.store.launchWarmupSuspension = {
            await withCheckedContinuation { continuation in
                resumeWarmup = continuation
                warmupPaused.trip()
            }
        }
        let pending = Task { await bundle.store.warmLaunchCaches(budgetID: "group-1") }
        await warmupPaused.wait()
        let resume = try #require(resumeWarmup)
        bundle.store.closeOpenBudget()
        resume.resume()
        await pending.value
        #expect(bundle.store.accountsByBudget.isEmpty)
        #expect(bundle.store.accountGroupsByBudget.isEmpty)
        #expect(bundle.store.payeesByBudget.isEmpty)
        #expect(bundle.store.actionLogDiagnosticSnapshot == .empty)
    }

    @Test func logoutDuringCachedRestoreCannotReconfigureSyncOrPublishOldBudget() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        bundle.store.reset()
        let state = try makeAppState(for: bundle)
        var resumeOpen: CheckedContinuation<Void, Never>?
        let openPaused = TestLatch()
        bundle.store.budgetOpenSuspension = {
            await withCheckedContinuation { continuation in
                resumeOpen = continuation
                openPaused.trip()
            }
        }
        let pending = Task { await state.beginForegroundSession() }
        await openPaused.wait()
        let resume = try #require(resumeOpen)
        state.disconnectAndEraseLocalData()
        resume.resume()
        await pending.value
        #expect(state.setupPhase == .needsConnection)
        #expect(state.settings.selectedBudgetID == nil)
        #expect(!bundle.store.hasOpenBudget)
        #expect(bundle.store.loadedBudgetMonthsByBudget.isEmpty)
        #expect(await bundle.store.syncClient.configuration == nil)
    }

    @Test func replacingBudgetDuringCachedRestoreKeepsNewSyncConfiguration() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        bundle.store.reset()
        let budget = ActualBudget(budgetID: "file-1", cloudFileId: "file-1", groupId: "group-1", name: "Budget", state: nil)
        var resumeOpen: CheckedContinuation<Void, Never>?
        let openPaused = TestLatch()
        bundle.store.budgetOpenSuspension = {
            await withCheckedContinuation { continuation in
                resumeOpen = continuation
                openPaused.trip()
            }
        }
        let pending = Task { try await bundle.store.openCachedBudget(budget) }
        await openPaused.wait()
        let resume = try #require(resumeOpen)
        bundle.store.closeOpenBudget()
        bundle.store.budgetOpenSuspension = nil
        #expect(try await bundle.store.openCachedBudget(budget))
        resume.resume()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(await bundle.store.syncClient.configuration?.fileID == "file-1")
    }

    @Test func logoutDuringDiscoveryCannotRepublishBudgetList() async throws {
        let remote = ActualSyncRemoteFile(fileID: "remote-file", groupID: "remote-group", name: "Remote Budget")
        let transport = StubConnectionTransport(files: [remote], listUserFilesDelay: .milliseconds(200))
        let bundle = try await makeOpenedWritableStoreBundle(connectionTransportFactory: { _ in transport })
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let pending = Task { try await bundle.store.loadBudgets(serverURLString: "https://synthetic.invalid") }
        await transport.waitForListUserFilesRequest()
        #expect(await transport.listUserFilesRequestCount > 0)
        try bundle.store.eraseLocalData()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(bundle.store.cachedBudgets.isEmpty)
        #expect(bundle.store.remoteFilesByFileID.isEmpty)
    }

    @Test func simultaneousDiscoverySharesOneRequestAndNewRetryCancelsOldWork() async throws {
        let remote = ActualSyncRemoteFile(fileID: "remote-file", groupID: "remote-group", name: "Remote Budget")
        let transport = StubConnectionTransport(files: [remote], listUserFilesDelay: .milliseconds(200))
        let bundle = try await makeOpenedWritableStoreBundle(connectionTransportFactory: { _ in transport })
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let recovery = AppSessionRecovery()
        let settings = AppSettings(localFirstServerURLString: "https://synthetic.invalid")
        let first = Task { try await recovery.discoverBudgets(settings: settings, store: bundle.store) }
        await transport.waitForListUserFilesRequest()
        #expect(await transport.listUserFilesRequestCount == 1)
        let second = Task { try await recovery.discoverBudgets(settings: settings, store: bundle.store) }
        #expect(try await first.value.budgets.count == 1)
        #expect(try await second.value.budgets.count == 1)
        #expect(await transport.listUserFilesRequestCount == 1)
        let interrupted = Task { try await recovery.discoverBudgets(settings: settings, store: bundle.store) }
        await transport.waitForListUserFilesRequest(atLeast: 2)
        recovery.invalidate()
        await #expect(throws: CancellationError.self) { _ = try await interrupted.value }
    }
}
