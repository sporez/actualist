import Foundation
import Testing
@testable import Actualist

/// Regression coverage for a remote budget whose encryption identity changes
/// while Actualist already has the budget open. The server refuses the next
/// sync with a `400`; Actualist must recognize the encryption change, present
/// an actionable error, and leave pending local writes intact.
@MainActor
extension LocalFirstActualStoreTests {
    private static let localKeyID = "local-key"
    private static let remoteKeyID = "remote-key"

    private var localEncryptionContext: ActualBudgetEncryptionContext {
        ActualBudgetEncryptionContext(
            keyID: Self.localKeyID,
            keyData: Data(repeating: 1, count: 32)
        )
    }

    private func remoteFile(encryptKeyID: String?) -> ActualSyncRemoteFile {
        ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-2",
            name: "Writable Budget",
            encryptKeyID: encryptKeyID,
            requiresEncryptionPassword: encryptKeyID != nil
        )
    }

    /// Opens the shared writable fixture, optionally as an encrypted budget,
    /// with a failing sync transport and a connection transport that reports
    /// the given live remote file metadata.
    private func makeEncryptionChangeBundle(
        openedEncryptionContext context: ActualBudgetEncryptionContext?,
        remoteFile: ActualSyncRemoteFile?,
        syncError: ActualAPIError,
        connectionTransport: ConfigurableConnectionTransport? = nil,
        pendingLocalMessageFlushRetryDelays: [Duration] = [.zero]
    ) async throws -> OpenedWritableStoreBundle {
        let connection = connectionTransport
            ?? ConfigurableConnectionTransport(files: remoteFile.map { [$0] } ?? [])
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in ErroringSyncTransport(error: syncError) },
            connectionTransportFactory: { _ in connection },
            pendingLocalMessageFlushRetryDelays: pendingLocalMessageFlushRetryDelays
        )
        try bundle.keychain.saveActualSyncToken("token")
        if let context {
            bundle.store.openedEncryptionContext = context
            await bundle.store.syncClient.configure(
                LocalFirstSyncConfiguration(
                    fileID: "file-1",
                    groupID: "group-1",
                    nodeID: "node1",
                    encryptionKeyID: context.keyID,
                    encryptionContext: context
                )
            )
        }
        return bundle
    }

    private func refresh(_ store: LocalFirstActualStore) async -> Error? {
        do {
            _ = try await store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
            return nil
        } catch {
            return error
        }
    }

    private func isEncryptionChanged(_ error: Error?) -> Bool {
        guard let error else { return false }
        return (error as? LocalFirstError) == .budgetEncryptionChanged
    }

    private func isSyncRejected(_ error: Error?, reason: ActualSyncRejectionReason) -> Bool {
        guard let error, case .syncRejected(_, let actual)? = error as? ActualAPIError else {
            return false
        }
        return actual == reason
    }

    @Test func openedUnencryptedBudgetRemoteEncryptionBecomesEncryptionChanged() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: nil,
            remoteFile: remoteFile(encryptKeyID: Self.remoteKeyID),
            syncError: .syncRejected(status: 400, reason: .fileHasReset)
        )

        #expect(isEncryptionChanged(await refresh(bundle.store)))
        #expect(
            bundle.store.syncStatus(budgetID: "group-1")?.lastError
                == LocalFirstError.budgetEncryptionChanged.localizedDescription
        )
    }

    @Test func openedEncryptedBudgetRemoteKeyChangesEncryptionChanged() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: localEncryptionContext,
            remoteFile: remoteFile(encryptKeyID: Self.remoteKeyID),
            syncError: .syncRejected(status: 400, reason: .fileHasReset)
        )

        #expect(isEncryptionChanged(await refresh(bundle.store)))
    }

    @Test func openedEncryptedBudgetRemoteEncryptionRemovedEncryptionChanged() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: localEncryptionContext,
            remoteFile: remoteFile(encryptKeyID: nil),
            syncError: .syncRejected(status: 400, reason: .fileHasReset)
        )

        #expect(isEncryptionChanged(await refresh(bundle.store)))
    }

    @Test func newKeyReasonIsEncryptionChangedWithoutMetadataLookup() async throws {
        let connection = ConfigurableConnectionTransport(files: [remoteFile(encryptKeyID: Self.remoteKeyID)])
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: localEncryptionContext,
            remoteFile: nil,
            syncError: .syncRejected(status: 400, reason: .fileHasNewKey),
            connectionTransport: connection
        )

        #expect(isEncryptionChanged(await refresh(bundle.store)))
        #expect(!(await connection.recordedMethods().contains(.userFileInfo)))
    }

    @Test func resetWithUnchangedEncryptionRemainsServerRejection() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: nil,
            remoteFile: remoteFile(encryptKeyID: nil),
            syncError: .syncRejected(status: 400, reason: .fileHasReset)
        )

        let error = await refresh(bundle.store)
        #expect(isSyncRejected(error, reason: .fileHasReset))
        #expect(!isEncryptionChanged(error))
    }

    @Test func ordinaryBadRequestRemainsGenericHTTPError() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: nil,
            remoteFile: remoteFile(encryptKeyID: nil),
            syncError: .httpStatus(400)
        )

        let error = await refresh(bundle.store)
        #expect(error?.localizedDescription == "The server returned HTTP 400.")
        #expect(!isEncryptionChanged(error))
    }

    @Test func transportFailureRemainsConnectivityError() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: nil,
            remoteFile: remoteFile(encryptKeyID: nil),
            syncError: .transport(.notConnectedToInternet)
        )

        let error = await refresh(bundle.store)
        #expect(isSyncRejected(error, reason: .fileHasReset) == false)
        #expect(!isEncryptionChanged(error))
        #expect(
            error?.localizedDescription == "This device is not connected to the network."
        )
    }

    @Test func pendingLocalWritesSurviveEncryptionChangeDetection() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: nil,
            remoteFile: remoteFile(encryptKeyID: Self.remoteKeyID),
            syncError: .syncRejected(status: 400, reason: .fileHasReset)
        )

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(expectedMode: nil,
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        #expect(pendingCount > 0)

        #expect(isEncryptionChanged(await refresh(bundle.store)))
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingCount)
    }

    @Test func matchingEncryptionMetadataKeepsSuccessfulEncryptedSync() async throws {
        let transport = RecordingSyncTransport()
        let context = localEncryptionContext
        let connection = ConfigurableConnectionTransport(files: [remoteFile(encryptKeyID: Self.localKeyID)])
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            connectionTransportFactory: { _ in connection }
        )
        try bundle.keychain.saveActualSyncToken("token")
        bundle.store.openedEncryptionContext = context
        await bundle.store.syncClient.configure(
            LocalFirstSyncConfiguration(
                fileID: "file-1",
                groupID: "group-1",
                nodeID: "node1",
                encryptionKeyID: context.keyID,
                encryptionContext: context
            )
        )

        _ = try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")

        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError == nil)
    }

    @Test func refreshPublishesSyncBlockedStatusForEncryptionChange() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: nil,
            remoteFile: remoteFile(encryptKeyID: Self.remoteKeyID),
            syncError: .syncRejected(status: 400, reason: .fileHasReset)
        )
        let state = try makeAppState(for: bundle)

        _ = await state.refreshLocalFirstData(budgetID: "group-1", force: true)

        #expect(state.connectionStatus == .syncBlocked)
        #expect(state.lastErrorMessage == LocalFirstError.budgetEncryptionChanged.localizedDescription)
    }

    @Test func refreshPublishesOfflineStatusForTransportFailure() async throws {
        let bundle = try await makeEncryptionChangeBundle(
            openedEncryptionContext: nil,
            remoteFile: nil,
            syncError: .transport(.notConnectedToInternet)
        )
        let state = try makeAppState(for: bundle)

        _ = await state.refreshLocalFirstData(budgetID: "group-1", force: true)

        #expect(state.connectionStatus == .offline)
    }
}
