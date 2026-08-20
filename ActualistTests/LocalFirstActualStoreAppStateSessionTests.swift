import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
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

    @Test func appStateAutomaticallySyncsOncePerForegroundSession() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)

        await appState.beginForegroundSession()
        await appState.beginForegroundSession()

        #expect(appState.setupPhase == .ready)
        #expect(await transport.messageCounts() == [0])

        appState.endForegroundSession()
        await appState.beginForegroundSession()

        #expect(await transport.messageCounts() == [0, 0])
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
        for _ in 0..<100 where !appState.isBudgetSwitchInProgress {
            await Task.yield()
        }

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

        let loaded = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        #expect(appState.setupPhase == .ready)
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
        #expect(appState.cachedSelectedBudgetMonth == nil)

        await appState.beginForegroundSession()

        let loaded = try #require(appState.cachedSelectedBudgetMonth)
        let firstFrameModel = BudgetViewModel(initialMonth: loaded)
        #expect(appState.setupPhase == .ready)
        #expect(appState.connectionStatus == .offline)
        #expect(!firstFrameModel.isLoading)
        #expect(firstFrameModel.budgetMonth != nil)
        #expect(loaded.month.categoryGroups.flatMap(\.categories).contains { $0.id == "groceries" })
    }
}
