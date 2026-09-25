import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func customHeaderReadFailurePreservesOpenBudgetAndRetryActuallySynchronizes() async throws {
        let backend = FakeKeychainBackend()
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport }, keychainBackend: backend
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        backend.copyFailureAccountStatuses["custom-http-headers"] = errSecInteractionNotAllowed
        let state = try makeAppState(for: bundle)
        await state.beginForegroundSession()
        #expect(state.setupPhase == .ready)
        #expect(try bundle.keychain.readActualSyncToken() == "synthetic-token")
        #expect(!(await state.refreshLocalFirstData(budgetID: "group-1")))
        #expect(state.connectionStatus == .offline)
        #expect(state.credentialRecoveryMessage == KeychainReadError.unavailable(errSecInteractionNotAllowed).localizedDescription)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        backend.copyFailureAccountStatuses = [:]
        await state.retryCredentialAccess()
        #expect(state.connectionStatus == .online)
        #expect(state.credentialRecoveryMessage == nil)
        #expect(await transport.messageCounts() == [0])
    }

    @Test func cachedOpenReportsUnreadableHeadersWithoutCallingBudgetOnline() async throws {
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() }, keychainBackend: backend
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let state = try makeAppState(for: bundle)
        bundle.store.reset()
        backend.copyFailureAccountStatuses["custom-http-headers"] = errSecAuthFailed
        let budget = ActualBudget(budgetID: "file-1", cloudFileId: "file-1", groupId: "group-1", name: "Budget", state: nil)
        await state.selectBudgetForCurrentBackend(budget)
        #expect(state.setupPhase == .ready)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(state.connectionStatus == .offline)
        #expect(state.credentialRecoveryMessage == KeychainReadError.unavailable(errSecAuthFailed).localizedDescription)
        backend.copyFailureAccountStatuses = [:]
        await state.retryCredentialAccess()
        #expect(state.connectionStatus == .online)
        #expect(state.credentialRecoveryMessage == nil)
    }

    @Test func logoutDuringRecoveryCannotCommitOldConnectionOrReopenBudget() async throws {
        let remote = ActualSyncRemoteFile(fileID: "file-1", groupID: "group-1", name: "Sample Budget")
        let transport = StubConnectionTransport(files: [remote], loginMethodsDelay: .milliseconds(250))
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("old-synthetic-token")
        let state = try makeAppState(for: bundle)
        await state.beginForegroundSession()
        let pending = Task {
            await state.saveLocalFirstConnection(serverURLString: "https://sync.example", password: "synthetic-password")
        }
        await transport.waitForLoginMethodsRequest()
        #expect(await transport.loginMethodsRequestCount > 0)
        state.disconnectAndEraseLocalData()
        #expect(!(await pending.value))
        #expect(state.setupPhase == .needsConnection)
        #expect(state.settings.selectedBudgetID == nil)
        #expect(try bundle.keychain.readActualSyncToken() == nil)
        #expect(!bundle.store.hasOpenBudget)
    }

    @Test func unavailableTokenOpensCachedBudgetAndRecoversWithoutReimport() async throws {
        let transport = RecordingSyncTransport()
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport }, keychainBackend: backend
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        bundle.store.reset()
        backend.copyFailureStatus = errSecInteractionNotAllowed
        let state = try makeAppState(for: bundle)

        await state.beginForegroundSession()
        #expect(state.setupPhase == .ready)
        #expect(state.connectionStatus == .offline)
        #expect(state.credentialRecoveryMessage != nil)
        #expect(!state.requiresReauthentication)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let originalDirectory = try bundle.fileManager.budgetDirectory(fileID: "file-1")
        #expect(FileManager.default.fileExists(atPath: originalDirectory.path))

        backend.copyFailureStatus = nil
        await state.retryCredentialAccess()
        #expect(state.setupPhase == .ready)
        #expect(state.credentialRecoveryMessage == nil)
        #expect(state.connectionStatus == .online)
        #expect(FileManager.default.fileExists(atPath: originalDirectory.path))
        #expect(try bundle.keychain.readActualSyncToken() == "synthetic-token")
    }

    @Test func noCacheAndUnavailableTokenBlocksInsteadOfOnboarding() async throws {
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() }, keychainBackend: backend
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        bundle.store.reset()
        try FileManager.default.removeItem(at: bundle.fileManager.budgetDirectory(fileID: "file-1"))
        backend.copyFailureStatus = errSecAuthFailed
        let state = try makeAppState(for: bundle)

        await state.beginForegroundSession()
        #expect(state.setupPhase == .credentialUnavailable)
        #expect(state.credentialRecoveryMessage != nil)
        #expect(state.settings.selectedBudgetID == "group-1")
        #expect(!state.requiresReauthentication)
        backend.copyFailureStatus = nil
        try bundle.keychain.removeActualSyncToken()
        await state.retryCredentialAccess()
        #expect(state.setupPhase == .needsConnection)
        #expect(state.settings.selectedBudgetID == "group-1")
    }

    @Test func unavailableEncryptionKeyDoesNotRequestNewPasswordOrClearSelection() async throws {
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() }, keychainBackend: backend
        )
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let metadataURL = try bundle.fileManager.metadataURL(fileID: "file-1")
        let original = try JSONDecoder.actual.decode(LocalFirstBudgetMetadata.self, from: Data(contentsOf: metadataURL))
        let encrypted = LocalFirstBudgetMetadata(
            localBudgetID: original.localBudgetID, cloudFileID: original.cloudFileID,
            groupID: original.groupID, budgetName: original.budgetName,
            encryptionKeyID: "key-1", nodeID: original.nodeID
        )
        try JSONEncoder.actual.encode(encrypted).write(to: metadataURL)
        try bundle.keychain.saveLocalFirstEncryptionKey(Data(repeating: 5, count: 32), fileID: "file-1", keyID: "key-1")
        bundle.store.reset()
        backend.copyFailureStatus = errSecInteractionNotAllowed
        let state = try makeAppState(for: bundle)

        await state.beginForegroundSession()
        #expect(state.setupPhase == .credentialUnavailable)
        #expect(state.lastErrorMessage != LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription)
        #expect(state.settings.selectedBudgetID == "group-1")
        backend.copyFailureStatus = nil
        await state.retryCredentialAccess()
        #expect(state.setupPhase == .ready)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
    }

    @Test func encryptedSelectionUnavailableKeyKeepsPreviouslyOpenBudget() async throws {
        let backend = FakeKeychainBackend()
        let bundle = try await makeOpenedWritableStoreBundle(keychainBackend: backend)
        let state = try makeAppState(for: bundle)
        await state.beginForegroundSession()
        let target = ActualBudget(
            budgetID: "file-2", cloudFileId: "file-2", groupId: "group-2",
            name: "Encrypted Sample", state: nil
        )
        bundle.store.remoteFilesByFileID["file-2"] = ActualSyncRemoteFile(
            fileID: "file-2", groupID: "group-2", name: "Encrypted Sample",
            encryptKeyID: "key-2", requiresEncryptionPassword: true
        )
        backend.copyFailureAccountStatuses["actual-encryption-key:file-2:key-2"] = errSecAuthFailed

        await state.selectBudgetForCurrentBackend(target)

        #expect(state.setupPhase == .ready)
        #expect(state.settings.selectedBudgetID == "group-1")
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(state.lastErrorMessage == KeychainReadError.unavailable(errSecAuthFailed).localizedDescription)
        #expect(state.lastErrorMessage != LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription)
        #expect(state.credentialRecoveryMessage != nil)
    }

    @Test func appStateConcurrentManualRefreshesJoinOneSync() async throws {
        let transport = RecordingSyncTransport(delayNanoseconds: 80_000_000)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)

        let firstRefresh = Task { @MainActor in
            await appState.refreshLocalFirstData(budgetID: "group-1", force: true)
        }
        let secondRefresh = Task { @MainActor in
            await appState.refreshLocalFirstData(budgetID: "group-1", force: true)
        }

        #expect(await firstRefresh.value)
        #expect(await secondRefresh.value)
        #expect(await transport.messageCounts() == [0])
        #expect(appState.localDataRevision == 1)
        #expect(appState.connectionStatus == .online)
    }

    @Test func postPresentationWorkRunsOncePerForegroundSession() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        var notificationPreparationCount = 0
        let appState = try makeAppState(
            for: bundle,
            notificationAuthorizationRequester: {
                notificationPreparationCount += 1
                return true
            }
        )
        appState.settings.backgroundTransactionRefreshEnabled = true

        await appState.beginForegroundSession()
        await appState.beginForegroundSession()

        #expect(appState.setupPhase == .ready)
        #expect(await transport.messageCounts().isEmpty)
        #expect(notificationPreparationCount == 0)

        let firstWarmup = try #require(appState.budgetDidPresent("group-1"))
        await firstWarmup.value
        #expect(await transport.messageCounts() == [0])
        #expect(notificationPreparationCount == 1)

        let duplicate = try #require(appState.budgetDidPresent("group-1"))
        await duplicate.value
        #expect(await transport.messageCounts() == [0])
        #expect(notificationPreparationCount == 1)

        appState.endForegroundSession()
        await appState.beginForegroundSession()
        let nextWarmup = try #require(appState.budgetDidPresent("group-1"))
        await nextWarmup.value

        #expect(await transport.messageCounts() == [0, 0])
        #expect(notificationPreparationCount == 2)
    }

    @Test func appStateRequiresTheSelectedBudgetDatabaseBeforeShowingMainTabs() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        await appState.beginForegroundSession()

        #expect(appState.isReadyForMainTabs)

        bundle.store.reset()

        #expect(appState.setupPhase == .ready)
        #expect(!appState.isReadyForMainTabs)
    }

    @Test func failedBudgetSwitchRestoresCurrentBudgetWithoutReplacingMainTabs() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        await appState.beginForegroundSession()
        let unavailableBudget = ActualBudget(
            budgetID: nil,
            cloudFileId: nil,
            groupId: nil,
            name: "Unavailable Budget",
            state: nil
        )

        await appState.selectBudgetForCurrentBackend(unavailableBudget)

        #expect(appState.setupPhase == .ready)
        #expect(appState.settings.selectedBudgetID == "group-1")
        #expect(appState.lastErrorMessage == LocalFirstError.missingBudgetFileID.localizedDescription)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(appState.isReadyForMainTabs)
    }

    @Test func encryptedBudgetSelectionPromptsBeforeClosingCurrentBudget() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        await appState.beginForegroundSession()
        let encryptedBudget = ActualBudget(
            budgetID: "file-2",
            cloudFileId: "file-2",
            groupId: "group-2",
            name: "Encrypted Budget",
            state: nil
        )
        bundle.store.remoteFilesByFileID["file-2"] = ActualSyncRemoteFile(
            fileID: "file-2",
            groupID: "group-2",
            name: "Encrypted Budget",
            encryptKeyID: "key-2",
            requiresEncryptionPassword: true
        )

        await appState.selectBudgetForCurrentBackend(encryptedBudget)

        #expect(appState.lastErrorMessage == LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription)
        #expect(appState.settings.selectedBudgetID == "group-1")
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(appState.setupPhase == .ready)
        #expect(appState.isReadyForMainTabs)
    }

    @Test func budgetSwitchKeepsMainTabsReadyWhileReplacementOpens() async throws {
        let transport = RecordingSyncTransport(delayNanoseconds: 300_000_000)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)
        appState.selectedBudget = bundle.budget
        appState.setupPhase = .ready
        appState.connectionStatus = .online

        let targetFileID = "file-2"
        let targetDirectory = try bundle.fileManager.budgetDirectory(fileID: targetFileID)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: bundle.fileManager.databaseURL(fileID: "file-1"),
            to: bundle.fileManager.databaseURL(fileID: targetFileID)
        )
        let targetMetadata = LocalFirstBudgetMetadata(
            localBudgetID: targetFileID,
            cloudFileID: targetFileID,
            groupID: "group-2",
            budgetName: "Replacement Budget",
            encryptionKeyID: nil,
            nodeID: "node2"
        )
        try JSONEncoder.actual.encode(targetMetadata).write(
            to: bundle.fileManager.metadataURL(fileID: targetFileID)
        )
        let targetBudget = ActualBudget(
            budgetID: targetFileID,
            cloudFileId: targetFileID,
            groupId: "group-2",
            name: "Replacement Budget",
            state: nil
        )

        let selectionTask = Task {
            await appState.selectBudgetForCurrentBackend(targetBudget)
        }
        await ObservedTestState { appState.isBudgetSwitchInProgress }.wait()

        #expect(appState.isBudgetSwitchInProgress)
        #expect(appState.setupPhase == .ready)
        #expect(appState.isReadyForMainTabs)

        await selectionTask.value

        #expect(!appState.isBudgetSwitchInProgress)
        #expect(appState.settings.selectedBudgetID == "group-2")
        #expect(bundle.store.isOpen(budgetID: "group-2"))
        #expect(appState.isReadyForMainTabs)
    }

    @Test func appStateKeepsRestoredSQLiteDataVisibleWhenForegroundSyncFails() async throws {
        let transport = RecordingSyncTransport(shouldFail: true)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)

        #expect(appState.setupPhase == .restoringBudget)

        await appState.beginForegroundSession()
        #expect(appState.setupPhase == .ready)
        #expect(appState.connectionStatus == .connecting)

        let postPresentation = try #require(appState.budgetDidPresent("group-1"))
        await postPresentation.value

        let loaded = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        #expect(appState.connectionStatus == .offline)
        #expect(appState.localDataRevision == 1)
        #expect(loaded.month.categoryGroups.flatMap(\.categories).contains { $0.id == "groceries" })
    }

    @Test func structuredAuthenticationFailureShowsReauthenticationBannerState() async throws {
        let transport = AuthenticationFailureSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("expired-token")
        let appState = try makeAppState(for: bundle)

        let succeeded = await appState.refreshLocalFirstData(
            budgetID: "group-1",
            force: true
        )

        #expect(!succeeded)
        #expect(appState.connectionStatus == .offline)
        #expect(appState.requiresReauthentication)
        #expect(
            appState.lastErrorMessage
                == "Your Actual session is no longer valid. Sign in again to resume syncing."
        )
    }

    @Test func successfulReauthenticationClearsExpiredSessionSyncError() async throws {
        let syncTransport = AuthenticationFailureSyncTransport()
        let remoteFile = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Writable Budget",
            deleted: false,
            encryptKeyID: nil,
            requiresEncryptionPassword: false
        )
        let connectionTransport = StubConnectionTransport(
            files: [remoteFile],
            token: "renewed-token"
        )
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in syncTransport },
            connectionTransportFactory: { _ in connectionTransport }
        )
        try bundle.keychain.saveActualSyncToken("expired-token")
        let appState = try makeAppState(for: bundle)

        let expiredRefreshSucceeded = await appState.refreshLocalFirstData(
            budgetID: "group-1",
            force: true
        )

        #expect(!expiredRefreshSucceeded)
        #expect(appState.requiresReauthentication)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError != nil)

        let reauthenticated = await appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "test-password"
        )

        #expect(reauthenticated)
        #expect(!appState.requiresReauthentication)
        #expect(appState.connectionStatus == .online)
        #expect(appState.lastErrorMessage == nil)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError == nil)
        #expect(appState.setupPhase == .ready)
        #expect(appState.settings.selectedBudgetID == "group-1")
        #expect(appState.settings.selectedLocalFirstFileID == "file-1")
        #expect(bundle.store.isOpen(budgetID: "group-1"))
    }

    @Test func authenticationWithMismatchedCachedBudgetReturnsToBudgetSelection() async throws {
        let remoteFile = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Writable Budget",
            deleted: false,
            encryptKeyID: nil,
            requiresEncryptionPassword: false
        )
        let connectionTransport = StubConnectionTransport(
            files: [remoteFile],
            token: "renewed-token"
        )
        let bundle = try await makeOpenedWritableStoreBundle(
            connectionTransportFactory: { _ in connectionTransport }
        )
        bundle.store.reset()
        let mismatchedMetadata = LocalFirstBudgetMetadata(
            localBudgetID: "file-1",
            cloudFileID: "file-1",
            groupID: "different-group",
            budgetName: "Writable Budget",
            encryptionKeyID: nil,
            nodeID: "node1"
        )
        try JSONEncoder.actual.encode(mismatchedMetadata).write(
            to: bundle.store.fileManager.metadataURL(fileID: "file-1")
        )
        let appState = try makeAppState(for: bundle)

        let authenticated = await appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "test-password"
        )

        #expect(authenticated)
        #expect(appState.hasSyncCredentials)
        #expect(appState.setupPhase == .selectingBudget)
        #expect(!appState.isReadyForMainTabs)
    }

    @Test func appStateRestoresSelectedSQLiteBudgetWithoutSyncCredentials() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        bundle.store.reset()
        let appState = try makeAppState(for: bundle)

        #expect(appState.setupPhase == .restoringBudget)
        #expect(appState.connectionStatus == .offline)
        #expect(bundle.store.cachedBudgetMonth(budgetID: "group-1") == nil)

        await appState.beginForegroundSession()

        let loaded = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let firstFrameModel = BudgetViewModel(initialMonth: loaded)
        #expect(appState.setupPhase == .ready)
        #expect(appState.connectionStatus == .offline)
        #expect(!firstFrameModel.isLoading)
        #expect(firstFrameModel.budgetMonth != nil)
        #expect(loaded.month.categoryGroups.flatMap(\.categories).contains { $0.id == "groceries" })
    }

    @Test func restoredSelectionWithoutLocalCacheReturnsToBudgetPickerAfterLogin() async throws {
        let remoteFile = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Restored Budget"
        )
        let connectionTransport = StubConnectionTransport(
            files: [remoteFile],
            token: "renewed-token"
        )
        let fixture = try makeRestoredSelectionAppState { _ in connectionTransport }
        let appState = fixture.appState

        #expect(appState.setupPhase == .restoringBudget)
        #expect(try fixture.keychain.readActualSyncToken() == nil)
        await appState.beginForegroundSession()
        #expect(appState.setupPhase == .needsConnection)

        let authenticated = await appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "correct-password"
        )

        #expect(authenticated)
        #expect(appState.lastErrorMessage == nil)
        #expect(appState.setupPhase == .selectingBudget)
        #expect(appState.budgets == [remoteFile.actualBudget])
        #expect(appState.settings.selectedBudgetID == nil)
        #expect(appState.settings.selectedLocalFirstFileID == nil)
        #expect(fixture.settingsStore.load().selectedBudgetID == nil)
        #expect(try fixture.keychain.readActualSyncToken() == "renewed-token")
    }

    @Test func restoredSelectionForUnavailableRemoteBudgetKeepsExistingState() async throws {
        let differentRemote = ActualSyncRemoteFile(
            fileID: "file-2",
            groupID: "group-2",
            name: "Different Budget"
        )
        let connectionTransport = StubConnectionTransport(files: [differentRemote])
        let fixture = try makeRestoredSelectionAppState { _ in connectionTransport }
        await fixture.appState.beginForegroundSession()

        let authenticated = await fixture.appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "correct-password"
        )

        #expect(!authenticated)
        #expect(
            fixture.appState.lastErrorMessage
                == LocalFirstError.selectedBudgetUnavailable.localizedDescription
        )
        #expect(fixture.appState.settings.selectedBudgetID == "group-1")
        #expect(fixture.settingsStore.load().selectedBudgetID == "group-1")
        #expect(try fixture.keychain.readActualSyncToken() == nil)
    }

    @Test func connectingToDifferentServerClearsRestoredSelection() async throws {
        let remoteFile = ActualSyncRemoteFile(
            fileID: "file-2",
            groupID: "group-2",
            name: "New Server Budget"
        )
        let connectionTransport = StubConnectionTransport(files: [remoteFile], token: "new-token")
        let fixture = try makeRestoredSelectionAppState(
            savedServerURLString: "https://old.example",
            connectionTransportFactory: { _ in connectionTransport }
        )

        let authenticated = await fixture.appState.saveLocalFirstConnection(
            serverURLString: "https://new.example",
            password: "correct-password"
        )

        #expect(authenticated)
        #expect(fixture.appState.settings.localFirstServerURLString == "https://new.example")
        #expect(fixture.appState.settings.selectedBudgetID == nil)
        #expect(fixture.appState.settings.selectedLocalFirstFileID == nil)
        #expect(fixture.appState.setupPhase == .selectingBudget)
        #expect(try fixture.keychain.readActualSyncToken() == "new-token")
    }

    @Test func restoredSelectionWithPresentCorruptCacheStillFailsValidation() async throws {
        let remoteFile = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Restored Budget"
        )
        let connectionTransport = StubConnectionTransport(files: [remoteFile])
        let fixture = try makeRestoredSelectionAppState { _ in connectionTransport }
        let directory = try fixture.fileManager.budgetDirectory(fileID: "file-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(
            to: fixture.fileManager.databaseURL(fileID: "file-1")
        )
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: "file-1",
            cloudFileID: "file-1",
            groupID: "group-1",
            budgetName: "Restored Budget",
            encryptionKeyID: nil,
            nodeID: "node"
        )
        try JSONEncoder.actual.encode(metadata).write(
            to: fixture.fileManager.metadataURL(fileID: "file-1")
        )
        await fixture.appState.beginForegroundSession()

        let authenticated = await fixture.appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "correct-password"
        )

        #expect(!authenticated)
        #expect(fixture.appState.settings.selectedBudgetID == "group-1")
        #expect(fixture.settingsStore.load().selectedBudgetID == "group-1")
        #expect(try fixture.keychain.readActualSyncToken() == nil)
        #expect(fixture.fileManager.importedDatabaseExists(fileID: "file-1"))
    }

    @Test func incorrectPasswordDoesNotEnterMissingCacheRecovery() async throws {
        let authenticationError = ActualAPIError.serverRejected(
            status: nil,
            reason: .invalidPassword
        )
        let connectionTransport = ConfigurableConnectionTransport(
            methodErrors: [.loginWithPassword: authenticationError]
        )
        let fixture = try makeRestoredSelectionAppState { _ in connectionTransport }
        await fixture.appState.beginForegroundSession()

        let authenticated = await fixture.appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "incorrect-password"
        )

        #expect(!authenticated)
        #expect(fixture.appState.lastErrorMessage == "The server password is incorrect.")
        #expect(fixture.appState.settings.selectedBudgetID == "group-1")
        #expect(try fixture.keychain.readActualSyncToken() == nil)
    }

    @Test func restoredEncryptedSelectionCanUnlockAndDownloadAfterRecovery() async throws {
        let password = "budget password"
        let salt = "server salt"
        let keyID = "restored-key-\(UUID().uuidString)"
        let keyData = try ActualBudgetCrypto.deriveKey(password: password, salt: salt)
        let context = ActualBudgetEncryptionContext(keyID: keyID, keyData: keyData)
        let archiveData = try makeArchiveData(databaseURL: makeSQLiteFixture())
        let encryptedArchive = try ActualBudgetCrypto.encrypt(archiveData, context: context)
        let encryptedTestValue = try ActualBudgetCrypto.encrypt(Data("test-value".utf8), context: context)
        let testPayload = ActualUserKeyResponse.TestPayload(
            value: encryptedTestValue.data.base64EncodedString(),
            meta: ActualEncryptedMetadata(
                keyID: keyID,
                algorithm: ActualBudgetCrypto.algorithm,
                iv: encryptedTestValue.iv.base64EncodedString(),
                authTag: encryptedTestValue.authTag.base64EncodedString()
            )
        )
        let userKeyResponse = ActualUserKeyResponse(
            id: keyID,
            salt: salt,
            test: String(data: try JSONEncoder.actual.encode(testPayload), encoding: .utf8)
        )
        let remoteFile = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Encrypted Budget",
            encryptKeyID: keyID,
            encryptMeta: ActualEncryptedMetadata(
                keyID: keyID,
                algorithm: ActualBudgetCrypto.algorithm,
                iv: encryptedArchive.iv.base64EncodedString(),
                authTag: encryptedArchive.authTag.base64EncodedString()
            ),
            requiresEncryptionPassword: true
        )
        let connectionTransport = ConfigurableConnectionTransport(
            files: [remoteFile],
            downloadData: encryptedArchive.data,
            userKeyResponse: userKeyResponse,
            token: "renewed-token"
        )
        let fixture = try makeRestoredSelectionAppState { _ in connectionTransport }
        defer {
            try? fixture.keychain.removeLocalFirstEncryptionKey(fileID: "file-1", keyID: keyID)
        }
        await fixture.appState.beginForegroundSession()
        let authenticated = await fixture.appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "correct-server-password"
        )
        #expect(authenticated)
        #expect(fixture.appState.lastErrorMessage == nil)
        let budget = try #require(fixture.appState.budgets.first)

        await fixture.appState.selectBudgetForCurrentBackend(budget)
        #expect(
            fixture.appState.lastErrorMessage
                == LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription
        )
        #expect(fixture.appState.setupPhase == .selectingBudget)

        await fixture.appState.selectBudgetForCurrentBackend(
            budget,
            encryptionPassword: password
        )

        #expect(fixture.appState.lastErrorMessage == nil)
        #expect(fixture.appState.setupPhase == .ready)
        #expect(fixture.appState.settings.selectedBudgetID == "group-1")
        #expect(fixture.appState.localFirstStore.isOpen(budgetID: "group-1"))
        #expect(fixture.appState.isReadyForMainTabs)
    }

    @Test func reconnectAfterEraseDoesNotReopenStaleSettingsPresentation() async throws {
        // Compact Settings is presented from BudgetView's fullScreenCover; the
        // disconnect/erase removes that host without a SwiftUI dismissal
        // callback. If the route coordinator keeps its visible state, the
        // next budget session re-presents Connection & Sync over the fresh
        // Budget tab. (Device report 2026-09-17.)
        let archiveData = try makeArchiveData(databaseURL: makeSQLiteFixture())
        let connectionTransport = StubConnectionTransport(
            files: [testRemoteFile()],
            token: "reconnect-token",
            downloadData: archiveData
        )
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in RecordingSyncTransport() },
            connectionTransportFactory: { _ in connectionTransport }
        )
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)
        await appState.beginForegroundSession()
        #expect(appState.isReadyForMainTabs)

        // Reproduce: Settings open in Connection & Sync when the user erases.
        appState.routeCoordinator.presentSettings(path: [.connection])
        appState.disconnectAndEraseLocalData()

        #expect(appState.setupPhase == .needsConnection)
        #expect(!appState.routeCoordinator.isSettingsPresented)
        #expect(appState.routeCoordinator.settingsPath.isEmpty)
        #expect(appState.routeCoordinator.pendingRoute == nil)

        // Reconnect and select a budget, as onboarding does after an erase.
        let reconnected = await appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "test-password"
        )
        #expect(reconnected)
        #expect(appState.setupPhase == .selectingBudget)
        #expect(appState.budgets.count == 1)

        await appState.selectBudgetForCurrentBackend(appState.budgets[0])

        #expect(appState.setupPhase == .ready)
        #expect(appState.isReadyForMainTabs)
        #expect(!appState.routeCoordinator.isSettingsPresented)
        #expect(appState.routeCoordinator.settingsPath.isEmpty)
        #expect(appState.routeCoordinator.pendingRoute == nil)
    }
}
